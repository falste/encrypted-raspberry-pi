# Configuration for build.sh. Copy to config.sh and adjust:
#   cp config.example.sh config.sh
# This file is sourced by bash, so use shell syntax.

# Raspberry Pi OS Lite (64-bit) image to build from. Pick a release from
# https://downloads.raspberrypi.com/raspios_lite_arm64/images/ and copy the
# .img.xz URL plus the checksum from the .sha256 file next to it.
IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-10-06/2026-10-06-raspios-trixie-arm64-lite.img.xz"
IMAGE_SHA256="483db18a48da399b5b7022ffae9a07bc6d99daab30e593aedac09b69ff422843"

# Name of the Pi on the network.
PI_HOSTNAME="raspberrypi"

# Login user. Gets passwordless sudo.
USER_NAME="pi"

# Public keys allowed to log in to the running system as USER_NAME
# (one per line).
SSH_AUTHORIZED_KEYS="
ssh-ed25519 AAAA... you@pc
"

# Public keys allowed to connect to the unlock prompt (one per line).
# Can be the same as above.
UNLOCK_AUTHORIZED_KEYS="$SSH_AUTHORIZED_KEYS"

# Port of the SSH server in the initramfs that asks for the passphrase.
UNLOCK_PORT=2222

# Console keyboard layout (XKB names), also used for the passphrase prompt
# on a locally attached keyboard.
KEYBOARD_LAYOUT="de"
KEYBOARD_MODEL="pc105"
KEYBOARD_VARIANT=""

TIMEZONE="Europe/Berlin"
LOCALE="en_US.UTF-8"

# Pass TRIM through the encryption and run fstrim weekly. Reveals which
# blocks of the disk are unused; keeps SSDs fast. Only has an effect if the
# USB-SATA adapter supports it (see README).
TRIM="yes"

# Where to write the finished image.
OUTPUT_IMAGE="raspios-encrypted.img"
