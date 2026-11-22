#!/bin/bash
# Builds a Raspberry Pi OS image with an encrypted root partition that can be
# unlocked over SSH (dropbear in the initramfs) or with a local keyboard.
#
# Usage: sudo ./build.sh [config file]    (default: config.sh)
set -euo pipefail

REPO_DIR=$(dirname "$(readlink -f "$0")")
CONFIG=$(readlink -f "${1:-config.sh}")
cd "$REPO_DIR"

# Name of the decrypted root device on the Pi (/dev/mapper/cryptroot).
MAPPER_NAME="cryptroot"
# Extra space added to the root partition, mostly for the package upgrade.
# On first boot the partition is grown to fill the whole disk anyway.
EXTRA_SIZE="2G"
LUKS_FORMAT_OPTIONS=(
    --type luks2
    --cipher 'xchacha12,aes-adiantum-plain64' # fast without AES hardware (Pi 4)
    --key-size 256
    --hash sha256
    --pbkdf argon2id
    --pbkdf-memory 512000
    --pbkdf-parallel 1
    --iter-time 5000
)

WORK_DIR="$REPO_DIR/work"
CACHE_DIR="$REPO_DIR/cache"
BASE_IMG="$WORK_DIR/base.img"
BASE_MNT="$WORK_DIR/base-root"
ROOT_MNT="$WORK_DIR/root"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Runs a command inside the image with a clean environment.
in_chroot() {
    chroot "$ROOT_MNT" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root LC_ALL=C DEBIAN_FRONTEND=noninteractive "$@"
}

# Prints the non-empty lines of a multi-line config value.
key_lines() { printf '%s\n' "$1" | sed -e 's/^[[:space:]]*//' -e '/^$/d'; }

check_keys() {
    local name=$1 value=$2
    key_lines "$value" | grep -qE '(^|[[:space:]])(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-[a-z0-9-]+@openssh\.com) ' ||
        die "$name contains no SSH public key"
    ! printf '%s' "$value" | grep -qF 'AAAA...' ||
        die "$name still contains the example key from config.example.sh"
}

#######################################################################
# Checks

[ "$EUID" -eq 0 ] || die "Run as root: sudo $0 ${1:-}"
[ -f "$CONFIG" ] || die "Config file $CONFIG not found. Start with: cp config.example.sh config.sh"
# shellcheck source=config.example.sh
. "$CONFIG"

[ -n "${IMAGE_URL:-}" ] || die "IMAGE_URL is not set"
[[ "$IMAGE_URL" == *.img.xz ]] || die "IMAGE_URL must point to an .img.xz file"
[[ "${IMAGE_SHA256:-}" =~ ^[0-9a-fA-F]{64}$ ]] || die "IMAGE_SHA256 must be the image's SHA256 checksum"
[[ "${PI_HOSTNAME:-}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid PI_HOSTNAME"
[[ "${USER_NAME:-}" =~ ^[a-z][-a-z0-9_]*$ ]] || die "Invalid USER_NAME"
[ "$USER_NAME" != root ] || die "USER_NAME must not be root"
[[ "${UNLOCK_PORT:-}" =~ ^[0-9]+$ ]] || die "Invalid UNLOCK_PORT"
if [ "$UNLOCK_PORT" -lt 1 ] || [ "$UNLOCK_PORT" -gt 65535 ]; then
    die "UNLOCK_PORT must be between 1 and 65535"
fi
[ "$UNLOCK_PORT" -ne 22 ] || die "UNLOCK_PORT must not be 22, the port of the running system's SSH server"
[[ "${TRIM:-}" == yes || "${TRIM:-}" == no ]] || die "TRIM must be yes or no"
for setting in KEYBOARD_LAYOUT TIMEZONE LOCALE; do
    [ -n "${!setting:-}" ] || die "$setting is not set"
done
[ -n "${OUTPUT_IMAGE:-}" ] || die "OUTPUT_IMAGE is not set"
check_keys SSH_AUTHORIZED_KEYS "${SSH_AUTHORIZED_KEYS:-}"
check_keys UNLOCK_AUTHORIZED_KEYS "${UNLOCK_AUTHORIZED_KEYS:-}"

for tool in cryptsetup losetup sfdisk rsync xz curl sha256sum chroot findmnt mountpoint udevadm; do
    command -v "$tool" >/dev/null || die "Missing tool on this machine: $tool"
done

if [ "$(uname -m)" != aarch64 ]; then
    binfmt=/proc/sys/fs/binfmt_misc/qemu-aarch64
    if [ ! -f "$binfmt" ] || ! grep -q '^flags:.*F' "$binfmt"; then
        die "Building on $(uname -m) needs arm64 emulation. Install qemu-user-static (with binfmt support)."
    fi
fi

OUTPUT_IMAGE=$(readlink -f "$OUTPUT_IMAGE")
PARTIAL_IMAGE="$OUTPUT_IMAGE.partial"

# The build machine may itself use a device called "cryptroot" (or the
# previous version's "crypted"), so open the new root under a free name.
BUILD_MAPPER="$MAPPER_NAME"
[ ! -e "/dev/mapper/$BUILD_MAPPER" ] || BUILD_MAPPER="encpi-build-$$"

#######################################################################
# Cleanup

BASE_LOOP=""
TARGET_LOOP=""
LUKS_OPENED=no
SUCCESS=no

mounts_in_work_dir() { findmnt -rn -o TARGET | grep -q "^$WORK_DIR\(/\|$\)"; }

cleanup() {
    set +e
    if mountpoint -q "$ROOT_MNT"; then
        umount -R "$ROOT_MNT" || umount -R -l "$ROOT_MNT"
    fi
    if mountpoint -q "$BASE_MNT"; then
        umount -R "$BASE_MNT" || umount -R -l "$BASE_MNT"
    fi
    [ "$LUKS_OPENED" = yes ] && cryptsetup close "$BUILD_MAPPER"
    [ -n "$TARGET_LOOP" ] && losetup -d "$TARGET_LOOP"
    [ -n "$BASE_LOOP" ] && losetup -d "$BASE_LOOP"
    # Never delete the work directory while something is still mounted in it
    # (the chroot has the build machine's /dev bind-mounted).
    if mounts_in_work_dir; then
        echo "WARNING: $WORK_DIR still has mounts, not deleting it" >&2
    else
        rm -rf --one-file-system "$WORK_DIR"
    fi
    if [ "$SUCCESS" != yes ]; then
        rm -f "$PARTIAL_IMAGE"
        printf '\nBuild failed, no image was written.\n' >&2
    fi
}
trap cleanup EXIT

#######################################################################
# Password

log "Password"
echo "Used for the disk encryption, the user '$USER_NAME' and root."
read -r -s -p "Password: " PASSWORD && echo
read -r -s -p "Confirm password: " PASSWORD_CONFIRM && echo
[ -n "$PASSWORD" ] || die "Password must not be empty"
[ "$PASSWORD" = "$PASSWORD_CONFIRM" ] || die "Passwords don't match"
unset PASSWORD_CONFIRM

#######################################################################
# Base image

log "Getting base image"
mkdir -p "$CACHE_DIR"
IMAGE_XZ="$CACHE_DIR/$(basename "$IMAGE_URL")"
image_ok() { echo "$IMAGE_SHA256  $IMAGE_XZ" | sha256sum --check --status; }
if [ -f "$IMAGE_XZ" ] && image_ok; then
    echo "Using cached $IMAGE_XZ"
else
    curl -fL --retry 3 -o "$IMAGE_XZ.download" "$IMAGE_URL"
    mv "$IMAGE_XZ.download" "$IMAGE_XZ"
    if ! image_ok; then
        rm -f "$IMAGE_XZ"
        die "Checksum of the downloaded image doesn't match IMAGE_SHA256"
    fi
fi

! mounts_in_work_dir || die "Something is still mounted below $WORK_DIR from an earlier run, unmount it first"
rm -rf --one-file-system "$WORK_DIR"
mkdir -p "$WORK_DIR" "$BASE_MNT" "$ROOT_MNT"
xz -dc "$IMAGE_XZ" > "$BASE_IMG"

#######################################################################
# Target image

log "Creating target image"
cp --sparse=always "$BASE_IMG" "$PARTIAL_IMAGE"
truncate -s "+$EXTRA_SIZE" "$PARTIAL_IMAGE"
echo ', +' | sfdisk --quiet --no-reread --no-tell-kernel -N 2 "$PARTIAL_IMAGE"

# Every copy of a Raspberry Pi OS release has the same partition IDs. Use new
# ones, so this disk can't be confused with another one (e.g. the old Pi disk).
DISK_ID=00000000
while [ "$DISK_ID" = 00000000 ]; do
    DISK_ID=$(od -An -tx4 -N4 /dev/urandom | tr -d ' \n')
done
sfdisk --quiet --disk-id "$PARTIAL_IMAGE" "0x$DISK_ID"

BASE_LOOP=$(losetup --read-only --partscan --find --show "$BASE_IMG")
TARGET_LOOP=$(losetup --partscan --find --show "$PARTIAL_IMAGE")
udevadm settle
for dev in "${BASE_LOOP}p2" "${TARGET_LOOP}p1" "${TARGET_LOOP}p2"; do
    [ -b "$dev" ] || die "Partition $dev did not show up"
done

log "Encrypting root partition (deriving the key takes a few seconds)"
printf '%s' "$PASSWORD" | cryptsetup luksFormat --batch-mode "${LUKS_FORMAT_OPTIONS[@]}" \
    --key-file=- "${TARGET_LOOP}p2"
printf '%s' "$PASSWORD" | cryptsetup open --key-file=- "${TARGET_LOOP}p2" "$BUILD_MAPPER"
LUKS_OPENED=yes
LUKS_UUID=$(cryptsetup luksUUID "${TARGET_LOOP}p2")

# Create the file system with the image's own mkfs, so it matches the Pi's
# tools no matter how old or new the build machine's are.
mount -o ro "${BASE_LOOP}p2" "$BASE_MNT"
mount --bind /dev "$BASE_MNT/dev"
mount --make-rslave "$BASE_MNT/dev"
mount -t proc proc "$BASE_MNT/proc"
chroot "$BASE_MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    mkfs.ext4 -q -L rootfs "/dev/mapper/$BUILD_MAPPER"
umount "$BASE_MNT/proc" "$BASE_MNT/dev"

log "Copying root file system"
mount "/dev/mapper/$BUILD_MAPPER" "$ROOT_MNT"
rsync --archive --hard-links --acls --xattrs --one-file-system --numeric-ids \
    "$BASE_MNT/" "$ROOT_MNT/"
umount "$BASE_MNT"
losetup -d "$BASE_LOOP"
BASE_LOOP=""
rm -f "$BASE_IMG"

#######################################################################
# Chroot

# Bind mounts are made rslave so unmounting them can never propagate back to
# the build machine's /dev.
mkdir -p "$ROOT_MNT/boot/firmware"
mount "${TARGET_LOOP}p1" "$ROOT_MNT/boot/firmware"
mount -t proc proc "$ROOT_MNT/proc"
mount -t sysfs sysfs "$ROOT_MNT/sys"
mount --bind /dev "$ROOT_MNT/dev"
mount --make-rslave "$ROOT_MNT/dev"
mount --bind /dev/pts "$ROOT_MNT/dev/pts"
mount --make-rslave "$ROOT_MNT/dev/pts"
mount -t tmpfs tmpfs "$ROOT_MNT/run"
mount -t tmpfs tmpfs "$ROOT_MNT/tmp"

R="$ROOT_MNT"
BOOT="$ROOT_MNT/boot/firmware"

# Network access for apt, and no services starting inside the chroot.
if [ -e "$R/etc/resolv.conf" ] || [ -L "$R/etc/resolv.conf" ]; then
    mv "$R/etc/resolv.conf" "$R/etc/resolv.conf.encpi-orig"
fi
cp -L /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"
chmod 755 "$R/usr/sbin/policy-rc.d"

#######################################################################
# Packages

log "Installing packages"
# Build the initramfs once at the end instead of after every package.
sed -i 's/^update_initramfs=.*/update_initramfs=no/' "$R/etc/initramfs-tools/update-initramfs.conf"
# Raspberry Pi OS uses MODULES=dep, which only includes drivers for the
# machine that builds the initramfs - here the build machine, not the Pi.
sed -i 's/^MODULES=.*/MODULES=most/' "$R/etc/initramfs-tools/initramfs.conf"

in_chroot apt-get update
in_chroot apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
in_chroot apt-get -y install --no-install-recommends \
    cryptsetup cryptsetup-initramfs dropbear-initramfs busybox xz-utils fdisk \
    unattended-upgrades
in_chroot apt-get -y autoremove --purge
in_chroot apt-get clean

#######################################################################
# System configuration

log "Configuring system"

# Files that are the same for every build.
cp -r --no-preserve=ownership "$REPO_DIR/files/." "$R/"
chmod 755 "$R/etc/initramfs-tools/hooks/encrypted-pi" \
    "$R/etc/initramfs-tools/scripts/init-premount/encrypted-pi-grow-partition" \
    "$R/usr/local/sbin/encrypted-pi-grow-root"

# Hostname
echo "$PI_HOSTNAME" > "$R/etc/hostname"
if grep -q '^127\.0\.1\.1' "$R/etc/hosts"; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$PI_HOSTNAME/" "$R/etc/hosts"
else
    printf '127.0.1.1\t%s\n' "$PI_HOSTNAME" >> "$R/etc/hosts"
fi

# Locale
grep -q "^$LOCALE " "$R/usr/share/i18n/SUPPORTED" || die "Unknown LOCALE: $LOCALE"
sed -i "s/^# *\($LOCALE \)/\1/" "$R/etc/locale.gen"
in_chroot locale-gen
in_chroot update-locale "LANG=$LOCALE"

# Timezone
[ -f "$R/usr/share/zoneinfo/$TIMEZONE" ] || die "Unknown TIMEZONE: $TIMEZONE"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
echo "$TIMEZONE" > "$R/etc/timezone"

# Keyboard layout for the console and the passphrase prompt in the initramfs
cat > "$R/etc/default/keyboard" <<EOF
XKBMODEL="${KEYBOARD_MODEL:-pc105}"
XKBLAYOUT="$KEYBOARD_LAYOUT"
XKBVARIANT="${KEYBOARD_VARIANT:-}"
XKBOPTIONS=""
BACKSPACE="guess"
EOF
in_chroot setupcon --force --save-only

# User. Raspberry Pi OS images may or may not ship a default user (uid 1000).
if ! in_chroot id "$USER_NAME" >/dev/null 2>&1; then
    old_user=$(in_chroot getent passwd 1000 | cut -d: -f1 || true)
    if [ -n "$old_user" ]; then
        old_group=$(in_chroot getent group 1000 | cut -d: -f1 || true)
        in_chroot usermod -l "$USER_NAME" -d "/home/$USER_NAME" -m "$old_user"
        [ -z "$old_group" ] || in_chroot groupmod -n "$USER_NAME" "$old_group"
        for file in "$R/etc/subuid" "$R/etc/subgid"; do
            [ ! -f "$file" ] || sed -i "s/^$old_user:/$USER_NAME:/" "$file"
        done
    else
        in_chroot useradd --create-home --shell /bin/bash "$USER_NAME"
    fi
fi
in_chroot usermod -s /bin/bash "$USER_NAME"
for group in adm dialout cdrom audio users sudo video plugdev input gpio spi i2c netdev render; do
    if in_chroot getent group "$group" >/dev/null; then
        in_chroot usermod -aG "$group" "$USER_NAME"
    fi
done
printf '%s:%s\nroot:%s\n' "$USER_NAME" "$PASSWORD" "$PASSWORD" | in_chroot chpasswd

SUDOERS_FILE="/etc/sudoers.d/010_$USER_NAME-nopasswd"
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$R$SUDOERS_FILE"
chmod 440 "$R$SUDOERS_FILE"
in_chroot visudo -cqf "$SUDOERS_FILE" || die "Generated sudoers file is invalid"

USER_HOME=$(in_chroot getent passwd "$USER_NAME" | cut -d: -f6)
USER_IDS=$(in_chroot id -u "$USER_NAME"):$(in_chroot id -g "$USER_NAME")
install -d -m 700 "$R$USER_HOME/.ssh"
key_lines "$SSH_AUTHORIZED_KEYS" > "$R$USER_HOME/.ssh/authorized_keys"
chmod 600 "$R$USER_HOME/.ssh/authorized_keys"
chown -R "$USER_IDS" "$R$USER_HOME/.ssh"

# No first-boot setup: the user exists already, and cloud-init or the user
# rename wizard would otherwise block the boot or change the configuration.
in_chroot systemctl mask userconfig.service
in_chroot systemctl enable getty@tty1.service
rm -f "$R/etc/ssh/sshd_config.d/rename_user.conf" "$R/etc/xdg/autostart/piwiz.desktop" \
    "$R/etc/sudoers.d/010_wiz-nopasswd"
rm -rf "$R/var/lib/userconf-pi"
if in_chroot id rpi-first-boot-wizard >/dev/null 2>&1; then
    in_chroot userdel -r rpi-first-boot-wizard
fi
if [ -d "$R/etc/cloud" ]; then
    touch "$R/etc/cloud/cloud-init.disabled"
fi
rm -f "$BOOT/user-data" "$BOOT/meta-data" "$BOOT/network-config" "$BOOT/firstrun.sh"

# SSH. Host keys are generated on first boot by Raspberry Pi OS; if that
# service ever goes away, generate them now (still unique per build).
in_chroot systemctl enable ssh.service
rm -f "$R"/etc/ssh/ssh_host_*_key*
if [ -f "$R/usr/lib/systemd/system/regenerate_ssh_host_keys.service" ]; then
    in_chroot systemctl enable regenerate_ssh_host_keys.service
else
    in_chroot ssh-keygen -A
fi

# Ethernet only
cat >> "$BOOT/config.txt" <<'EOF'

[all]
# encrypted-raspberry-pi: Ethernet only
dtoverlay=disable-wifi
dtoverlay=disable-bt
EOF
in_chroot systemctl mask hciuart.service bluetooth.service

in_chroot systemctl enable encrypted-pi-grow-root.service
if [ "$TRIM" = yes ]; then
    in_chroot systemctl enable fstrim.timer
fi

#######################################################################
# Boot configuration

log "Configuring encrypted boot"

CRYPTTAB_OPTIONS="luks,initramfs"
[ "$TRIM" = no ] || CRYPTTAB_OPTIONS="luks,discard,initramfs"
printf '%s UUID=%s none %s\n' "$MAPPER_NAME" "$LUKS_UUID" "$CRYPTTAB_OPTIONS" > "$R/etc/crypttab"

awk -v boot="PARTUUID=$DISK_ID-01" -v root="/dev/mapper/$MAPPER_NAME" '
    $2 == "/"              { $1 = root; found_root = 1 }
    $2 == "/boot/firmware" { $1 = boot; found_boot = 1 }
    { print }
    END { if (!found_root || !found_boot) exit 1 }
' OFS='\t' "$R/etc/fstab" > "$R/etc/fstab.new" || die "Unexpected /etc/fstab in base image"
mv "$R/etc/fstab.new" "$R/etc/fstab"

# Kernel command line: root on the decrypted device. Drop "resize" (its
# initramfs scripts expect an unencrypted root and would reboot) and any
# first-boot hooks.
CMDLINE=$(tr -s ' \n' '\n' < "$BOOT/cmdline.txt" |
    { grep -vE '^(root=|resize$|init=|systemd\.run|systemd\.unit=|cryptdevice=)' || true; } |
    tr '\n' ' ' | sed 's/^ *//; s/ *$//')
echo "$CMDLINE root=/dev/mapper/$MAPPER_NAME" > "$BOOT/cmdline.txt"
grep -q '^auto_initramfs=1' "$BOOT/config.txt" ||
    die "Base image config.txt lacks auto_initramfs=1, this script needs updating"

# Unlock over SSH: only the passphrase prompt, no shell, no forwarding,
# no password logins; disconnect after 5 idle minutes.
key_lines "$UNLOCK_AUTHORIZED_KEYS" > "$R/etc/dropbear/initramfs/authorized_keys"
chmod 600 "$R/etc/dropbear/initramfs/authorized_keys"
cat > "$R/etc/dropbear/initramfs/dropbear.conf" <<EOF
# Managed by encrypted-raspberry-pi. Run "update-initramfs -u -k all" after changes.
DROPBEAR_OPTIONS="-p $UNLOCK_PORT -s -j -k -I 300 -c /bin/cryptroot-unlock"
EOF

#######################################################################
# Initramfs

log "Building initramfs"
if [ "$BUILD_MAPPER" != "$MAPPER_NAME" ]; then
    echo "Note: the build machine already uses /dev/mapper/$MAPPER_NAME, so warnings from the"
    echo "cryptroot hook about a source mismatch or missing crypttab entry are expected."
fi
sed -i 's/^update_initramfs=.*/update_initramfs=yes/' "$R/etc/initramfs-tools/update-initramfs.conf"
for dir in "$R"/lib/modules/*; do
    version=${dir##*/}
    [ -e "$R/boot/vmlinuz-$version" ] || continue
    if [ -e "$R/boot/initrd.img-$version" ]; then
        in_chroot update-initramfs -u -k "$version"
    else
        in_chroot update-initramfs -c -k "$version"
    fi
done

log "Checking initramfs"
# The Pi 4 boots kernel8.img with initramfs8 from the boot partition.
V8_VERSION=$(find "$R/lib/modules" -mindepth 1 -maxdepth 1 -name '*-rpi-v8' -printf '%f\n' | sort -V | tail -n 1)
[ -n "$V8_VERSION" ] || die "No Raspberry Pi v8 kernel installed"
INITRD="$R/boot/initrd.img-$V8_VERSION"
cmp -s "$INITRD" "$BOOT/initramfs8" ||
    die "initramfs8 on the boot partition is not the freshly built initramfs for $V8_VERSION"

in_chroot unmkinitramfs "/boot/initrd.img-$V8_VERSION" /tmp/initrd
INITRD_DIR="$R/tmp/initrd"
[ ! -d "$INITRD_DIR/main" ] || INITRD_DIR="$INITRD_DIR/main"
check_initrd() { [ -n "$(find "$INITRD_DIR" -path "$INITRD_DIR/$1" -print -quit)" ] || die "initramfs: $2"; }
grep -q "^$MAPPER_NAME UUID=$LUKS_UUID " "$INITRD_DIR/cryptroot/crypttab" 2>/dev/null ||
    die "initramfs: root device missing from cryptroot/crypttab"
check_initrd "*sbin/dropbear" "dropbear missing"
check_initrd "*/.ssh/authorized_keys" "unlock keys missing"
grep -q -- "-p $UNLOCK_PORT " "$INITRD_DIR/etc/dropbear/dropbear.conf" || die "initramfs: dropbear config missing"
grep -q '^TIMEOUT=60$' "$INITRD_DIR/bin/cryptroot-unlock" 2>/dev/null ||
    grep -q '^TIMEOUT=60$' "$INITRD_DIR/usr/bin/cryptroot-unlock" || die "initramfs: cryptroot-unlock timeout not set"
check_initrd "etc/boottime.kmap.gz" "keyboard layout missing"
check_initrd "scripts/init-premount/encrypted-pi-grow-partition" "partition grow script missing"
check_initrd "*sbin/sfdisk" "sfdisk missing"
rm -rf "$R/tmp/initrd"
echo "initramfs looks good"

#######################################################################
# Finish

log "Cleaning up image"
UNLOCK_FINGERPRINTS=$(for key in "$R"/etc/dropbear/initramfs/dropbear_*_host_key; do
    in_chroot dropbearkey -y -f "${key#"$R"}" | grep -i fingerprint || true
done)

rm -f "$R/usr/sbin/policy-rc.d"
rm -f "$R/etc/resolv.conf"
if [ -e "$R/etc/resolv.conf.encpi-orig" ] || [ -L "$R/etc/resolv.conf.encpi-orig" ]; then
    mv "$R/etc/resolv.conf.encpi-orig" "$R/etc/resolv.conf"
fi
# Unique per device, generated on first boot.
echo "uninitialized" > "$R/etc/machine-id"
rm -f "$R/var/lib/dbus/machine-id"
rm -f "$R"/etc/{passwd,group,shadow,gshadow,subuid,subgid}- "$R/root/.bash_history"
find "$R/var/log" -type f -exec truncate -s 0 {} +

umount -R "$ROOT_MNT"
cryptsetup close "$BUILD_MAPPER"
LUKS_OPENED=no
losetup -d "$TARGET_LOOP"
TARGET_LOOP=""

mv "$PARTIAL_IMAGE" "$OUTPUT_IMAGE"
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown "$SUDO_UID:$SUDO_GID" "$OUTPUT_IMAGE"
fi
SUCCESS=yes

log "Done: $OUTPUT_IMAGE"
cat <<EOF

Unlock SSH server host key fingerprints (port $UNLOCK_PORT):
$UNLOCK_FINGERPRINTS

Next steps:
  1. Flash the image, e.g.: sudo dd if=$OUTPUT_IMAGE of=/dev/sdX bs=4M conv=fsync status=progress
  2. Boot the Pi from it, then unlock: ssh -p $UNLOCK_PORT root@<pi-address>
     (or type the password on a keyboard attached to the Pi)
  3. Log in: ssh $USER_NAME@<pi-address>
EOF
