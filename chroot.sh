#!/bin/bash
set -e

img_target="raspios_out.img"

cleanup() {
    set +e
    {
        umount /mnt/chroot/boot
        umount /mnt/chroot/sys
        umount /mnt/chroot/proc
        umount /mnt/chroot/dev/pts
        umount /mnt/chroot/dev
        umount /mnt/chroot
        cryptsetup close crypted
        rm -d /mnt/chroot
        kpartx -d "$img_target"
        cryptsetup luksClose cryptroot
        dev_target=$(losetup | grep "$img_target" | sed -e 's/\/dev\/\(\w\+\) .*/\1/')
        losetup -d "/dev/$dev_target"
    } &> /dev/null
}
trap cleanup EXIT

read -r -s -p "Enter decryption password: " decrypt_password && echo

if [ ! -f "$img_target" ]; then
    echo "Can't find image $img_target"
    exit
fi

kpartx -a "$img_target"
dev_target=$(losetup | grep "$img_target" | sed -e 's/\/dev\/\(\w\+\) .*/\1/')
cryptsetup luksOpen "/dev/mapper/${dev_target}p2" crypted <<< "$decrypt_password"
mkdir -p /mnt/chroot
mount /dev/mapper/crypted /mnt/chroot
chroot /mnt/chroot

