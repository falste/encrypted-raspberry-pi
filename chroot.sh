#!/bin/bash
# Opens an encrypted image or disk and starts a shell inside it, e.g. to
# inspect a built image or to repair the Pi's disk from another Linux machine.
# Everything is unmounted and closed again when the shell exits.
#
# Usage: sudo ./chroot.sh [image file or disk device]   (default: raspios-encrypted.img)
set -euo pipefail

TARGET=${1:-raspios-encrypted.img}
MAPPER="encpi-chroot-$$"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || die "Run as root: sudo $0 $*"
[ -e "$TARGET" ] || die "$TARGET not found"
if [ "$(uname -m)" != aarch64 ] && [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    die "Running arm64 programs on $(uname -m) needs qemu-user-static (with binfmt support)"
fi

LOOP=""
LUKS_OPENED=no
MNT=$(mktemp -d /tmp/encpi-chroot.XXXXXX)

cleanup() {
    set +e
    if mountpoint -q "$MNT"; then
        umount -R "$MNT" || umount -R -l "$MNT"
    fi
    [ "$LUKS_OPENED" = yes ] && cryptsetup close "$MAPPER"
    [ -n "$LOOP" ] && losetup -d "$LOOP"
    # Only remove the mount point once nothing is mounted there any more.
    mountpoint -q "$MNT" || rmdir "$MNT"
}
trap cleanup EXIT

if [ -b "$TARGET" ]; then
    DISK=$TARGET
else
    LOOP=$(losetup --partscan --find --show "$TARGET")
    udevadm settle
    DISK=$LOOP
fi
mapfile -t PARTS < <(lsblk -lnpo NAME,TYPE "$DISK" | awk '$2 == "part" { print $1 }')
[ "${#PARTS[@]}" -ge 2 ] || die "$DISK doesn't have a boot and a root partition"
BOOT_PART=${PARTS[0]}
ROOT_PART=${PARTS[1]}
if findmnt -rn -S "$BOOT_PART" >/dev/null || findmnt -rn -S "$ROOT_PART" >/dev/null; then
    die "$DISK is mounted, unmount it first"
fi

cryptsetup open "$ROOT_PART" "$MAPPER"
LUKS_OPENED=yes
mount "/dev/mapper/$MAPPER" "$MNT"
mount "$BOOT_PART" "$MNT/boot/firmware"
mount -t proc proc "$MNT/proc"
mount -t sysfs sysfs "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --make-rslave "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --make-rslave "$MNT/dev/pts"
mount -t tmpfs tmpfs "$MNT/run"
mount -t tmpfs tmpfs "$MNT/tmp"

echo "Root of $TARGET mounted at $MNT (boot partition at /boot/firmware)."
echo "No network inside unless you copy a resolv.conf. Exit the shell to close everything."
chroot "$MNT" /bin/bash -l || true
