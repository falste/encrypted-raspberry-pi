#!/bin/bash
set -e

img_base="raspios_base.img"
img_target="raspios_out.img"

cleanup() {
    set +e
    printf "\n# Cleaning up...\n"
    {
        umount /mnt/chroot/boot
        umount /mnt/chroot/sys
        umount /mnt/chroot/proc
        umount /mnt/chroot/dev/pts
        umount /mnt/chroot/dev
        umount /mnt/chroot
        cryptsetup close crypted
        umount /mnt/base
        rm -d /mnt/chroot
        rm -d /mnt/base
        kpartx -d "$img_base"
        kpartx -d "$img_target"
    
        cryptsetup luksClose cryptroot
    
        dev_base=$(losetup | grep "$img_base" | sed -e 's/\/dev\/\(\w\+\) .*/\1/')
        dev_target=$(losetup | grep "$img_target" | sed -e 's/\/dev\/\(\w\+\) .*/\1/')
    
        losetup -d "/dev/$dev_base"
        losetup -d "/dev/$dev_target"
    } &> /dev/null
}
trap cleanup EXIT

read -r -s -p "Enter decryption password: " decrypt_password && echo
read -r -s -p "Confirm password: " tmp && echo
if [ "$decrypt_password" != "$tmp" ]; then
    echo "Passwords don't match!" >&2 && exit -1
fi
read -r -s -p "Enter root user password: " root_password && echo
read -r -s -p "Confirm password: " tmp && echo
if [ "$root_password" != "$tmp" ]; then
    echo "Passwords don't match!" >&2 && exit -1
fi

url=$(head -n 1 config/image_url)
unlock_port=$(head -n 1 config/unlock_port)

printf "\n# Preparing images...\n"
# Download the Raspberry Pi OS Lite image if not already downloaded
if [ -f "$img_base" ]; then
    echo "Image already present, skipping download."
else
    wget -O "${img_base}.xz" "$url"
    xz -d "${img_base}.xz"
fi

cp $img_base $img_target

qemu-img resize -f raw $img_target +1G
parted $img_target resizepart 2 100%

printf "\n# Mounting images...\n"
kpartx -ar "$img_base"
kpartx -a "$img_target"

dev_base=$(losetup | grep "$img_base" | sed -e 's/\/dev\/\(\w\+\) .*/\1/')
dev_target=$(losetup | grep "$img_target" | sed -e 's/\/dev\/\(\w\+\) .*/\1/')

echo "Using loop devices $dev_base and $dev_target"

mkdir -p /mnt/base
mount /dev/mapper/${dev_base}p2 /mnt/base

printf "\n# Creating encrypted partition...\n"
cryptsetup --verbose --type=luks2 --cipher=xchacha12,aes-adiantum-plain64 --pbkdf-memory 512000 --pbkdf-parallel=1 --key-size=256 --hash=sha256 --iter-time=5000 --use-random luksFormat "/dev/mapper/${dev_target}p2" <<< "$decrypt_password"
cryptsetup luksOpen "/dev/mapper/${dev_target}p2" crypted <<< "$decrypt_password"

mkfs.ext4 /dev/mapper/crypted

printf "\n# Mounting encrypted partition...\n"
mkdir -p /mnt/chroot
mount /dev/mapper/crypted /mnt/chroot

printf "\n# Copying file system...\n"
rsync --archive --hard-links --acls --xattrs --one-file-system --numeric-ids --info="progress2" /mnt/base/* /mnt/chroot/

printf "\n# Preparing chroot...\n"
mkdir -p /mnt/chroot/boot/
mkdir -p /mnt/chroot/proc/
mkdir -p /mnt/chroot/sys/
mkdir -p /mnt/chroot/dev/pts/

mount /dev/mapper/${dev_target}p1 /mnt/chroot/boot/
mount -t proc none /mnt/chroot/proc/
mount -t sysfs none /mnt/chroot/sys/
mount -o bind /dev /mnt/chroot/dev/
mount -o bind /dev/pts /mnt/chroot/dev/pts/

printf "\n# Configuring device...\n"
chroot /mnt/chroot /bin/bash -c "mv /etc/resolv.conf /etc/resolv.conf.bak"
chroot /mnt/chroot /bin/bash -c "echo \"nameserver 1.1.1.1\" > /etc/resolv.conf"

chroot /mnt/chroot /bin/bash -c "apt update && apt autoremove"
chroot /mnt/chroot /bin/bash -c "apt upgrade -y"
chroot /mnt/chroot /bin/bash -c "apt install -y busybox cryptsetup dropbear-initramfs"

chroot /mnt/chroot /bin/bash -c "mkdir -p /root/.ssh"
cp -n config/unlock_authorized_keys /mnt/chroot/etc/dropbear-initramfs/authorized_keys
cp -n config/authorized_keys /mnt/chroot/root/.ssh/authorized_keys

chroot /mnt/chroot /bin/bash -c "sed -E -i 's@.*/\s+ext4.*@/dev/mapper/crypted   / ext4 defaults,noatime          0 1@' /etc/fstab"
uuid=$(chroot /mnt/chroot /bin/bash -c "blkid | grep crypto_LUKS | grep -oP \" UUID=\\\"\K[^\\\"]+\"")
chroot /mnt/chroot /bin/bash -c "blkid"

chroot /mnt/chroot /bin/bash -c "echo \"crypted UUID=${uuid} none luks,initramfs\" >> /etc/crypttab"
chroot /mnt/chroot /bin/bash -c "sed -i 's/\(.*root=\)[^[:space:]]*/\1\/dev\/mapper\/crypted cryptdevice=UUID=${uuid}:crypted/' /boot/cmdline.txt"

chroot /mnt/chroot /bin/bash -c "echo \"CRYPTSETUP=y\" >> /etc/cryptsetup-initramfs/conf-hook"
chroot /mnt/chroot /bin/bash -c "patch --no-backup-if-mismatch /usr/share/initramfs-tools/hooks/cryptroot << 'EOF'
--- cryptroot
+++ cryptroot
@@ -33,7 +33,7 @@
         printf '%s\0' \"\$target\" >>\"\$DESTDIR/cryptroot/targets\"
         crypttab_find_entry \"\$target\" || return 1
         crypttab_parse_options --missing-path=warn || return 1
-        crypttab_print_entry
+        printf '%s %s %s %s\n' \"\$_CRYPTTAB_NAME\" \"\$_CRYPTTAB_SOURCE\" \"\$_CRYPTTAB_KEY\" \"\$_CRYPTTAB_OPTIONS\" >&3
     fi
 }
EOF"
chroot /mnt/chroot /bin/bash -c "sed -i 's/^TIMEOUT=.*/TIMEOUT=60/g' /usr/share/cryptsetup/initramfs/bin/cryptroot-unlock"

raspi_kernel=$(chroot /mnt/chroot /bin/bash -c "ls /lib/modules" | head -n 1)
chroot /mnt/chroot /bin/bash -c "sed -i 's/^#INITRD=Yes$/INITRD=Yes/g' /etc/default/raspberrypi-kernel"
chroot /mnt/chroot /bin/bash -c "mkinitramfs -o /boot/initrd.img-$raspi_kernel \"$raspi_kernel\""
chroot /mnt/chroot /bin/bash -c "echo \"initramfs initrd.img-$raspi_kernel followkernel\" >> /boot/config.txt"

chroot /mnt/chroot /bin/bash -c "sed -i 's/^main$/fix_wpa;regenerate_ssh_host_keys/g' /usr/lib/raspberrypi-sys-mods/firstboot"
chroot /mnt/chroot /bin/bash -c "echo \"pi:\$6\$Gpq1Y5a26F7cPIuL\$VeIz04vCAZFE6RfFnH.BInFyiHp.pylFKzLYoVfDav1dCYAeUJqISZngIaQNcdr1SJfJWXbmBk7DftioULVYW0\" > /boot/userconf.txt"

chroot /mnt/chroot /bin/bash -c "mkdir -p /etc/dropbear"
chroot /mnt/chroot /bin/bash -c "echo 'DROPBEAR_OPTIONS=\"-p $unlock_port\"' > /etc/dropbear/dropbear.conf"
chroot /mnt/chroot /bin/bash -c "update-initramfs -u"

chroot /mnt/chroot /bin/bash -c "mv /etc/resolv.conf.bak /etc/resolv.conf"

echo "root:${root_password}" | chroot /mnt/chroot chpasswd

cp -rn system_files/* /mnt/chroot
chroot /mnt/chroot /bin/bash -c "systemctl enable resize.service"


cp -rn custom_files/* /mnt/chroot

chroot /mnt/chroot /bin/bash -c "sync && history -c"
