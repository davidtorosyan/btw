#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
#   curl -sL bit.ly/btwarch | bash
# Copied from https://github.com/mdaffin/arch-pkgs/blob/bc9575362c9b0dd38b414c42b5b9c79b0630228c/installer/install-arch
# Line endings have to be LF
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# Make sure to run this first to check we're in UEFI (TODO add to script):
# ls /sys/firmware/efi/efivars

# Find a way to check for intel

MIRRORLIST_URL="https://archlinux.org/mirrorlist/?country=US&protocol=https&use_mirror_status=on"

# In case this fails, try these commands. Probably add them to the script too.
# killall gpg-agent
# rm -rf /etc/pacman.d/gnupg/
# pacman-key --init
# pacman-key --populate archlinux

pacman -Sy --noconfirm archlinux-keyring pacman-contrib dialog

echo "Updating mirror list"
curl -s "$MIRRORLIST_URL" | \
    sed -e 's/^#Server/Server/' -e '/^#/d' | \
    rankmirrors -n 5 - > /etc/pacman.d/mirrorlist

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

staticip=$(dialog --stdout --inputbox "Enter static ip" 0 0) || exit 1
clear
: ${staticip:?"staticip cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installtion disk" 0 0 0 ${devicelist}) || exit 1
clear

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
swap_end=$(( $swap_size + 129 + 1 ))MiB

# In case this fails, use parted to delete the existing partitions then restart.
parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 129MiB \
  set 1 boot on \
  mkpart primary linux-swap 129MiB ${swap_end} \
  mkpart primary btrfs ${swap_end} 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

wipefs "${part_boot}"
wipefs "${part_swap}"
wipefs "${part_root}"

mkfs.vfat -F32 "${part_boot}"
mkswap "${part_swap}"
mkfs.btrfs -f "${part_root}"

swapon "${part_swap}"
mount "${part_root}" /mnt
mkdir /mnt/boot
mount "${part_boot}" /mnt/boot

### Install and configure the basic system ###
pacstrap -K /mnt \
  base linux linux-firmware \
  intel-ucode \
  base-devel \
  zsh sudo \
  btrfs-progs \
  git github-cli
genfstab -t PARTUUID /mnt >> /mnt/etc/fstab
echo "${hostname}" > /mnt/etc/hostname

# Use systemd-boot as the bootloader
arch-chroot /mnt bootctl install

cat <<EOF > /mnt/boot/loader/loader.conf
default arch
EOF

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux
initrd   /intel-ucode.img
initrd   /initramfs-linux.img
options  root=PARTUUID=$(blkid -s PARTUUID -o value "$part_root") rw
EOF

echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
arch-chroot /mnt ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
arch-chroot /mnt hwclock --systohc

arch-chroot /mnt useradd -mU -s /usr/bin/zsh -G wheel "$user"
arch-chroot /mnt chsh -s /usr/bin/zsh
echo "# Created by btw" > "/mnt/home/$user/.zshrc"
arch-chroot /mnt chown $user:$user "/home/$user/.zshrc"

cat <<EOF > "/mnt/etc/sudoers.d/00_$user"
$user ALL=(ALL) ALL
EOF
arch-chroot /mnt chmod 440 "/etc/sudoers.d/00_$user"

echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

gatewayip="${staticip%.*}.1"
cat <<EOF > "/etc/systemd/network/20-wired.network"
[Match]
Name=eno1

[Network]
Address=$staticip/24
Gateway=$gatewayip
DNS=8.8.8.8
EOF
arch-chroot /mnt systemctl enable systemd-networkd.service
arch-chroot /mnt systemctl enable systemd-networkd-wait-online@eno1.service

echo "Completed basic setup, configuring btw."

pkgdir=/opt/btw-private
arch-chroot /mnt mkdir $pkgdir
arch-chroot /mnt chown $user:$user $pkgdir

arch-chroot /mnt su $user << EOF
gh auth login -p https -w
gh auth setup-git
git clone https://github.com/davidtorosyan/btw-private.git $pkgdir
cd $pkgdir
makepkg -sif --noconfirm
rm -rf pkg build dist src/*.egg-info || true
EOF

cat <<EOF > /mnt/usr/bin/btwup
#!/bin/bash
set -uo pipefail
trap 's=\$?; echo "\$0: Error on line "\$LINENO": \$BASH_COMMAND"; exit \$s' ERR

cd $pkgdir
git pull
makepkg -sif --noconfirm
rm -rf pkg build dist src/*.egg-info || true
EOF
arch-chroot /mnt chmod +x "/usr/bin/btwup"

arch-chroot /mnt su $user << EOF
export _TYPER_COMPLETE_TEST_DISABLE_SHELL_DETECTION=True
btw --install-completion zsh
EOF
echo "compinit" >> "/mnt/home/$user/.zshrc"

echo "Done! You can now reboot and remove the boot media."