# Encrypted Raspberry Pi

Builds a ready-to-flash Raspberry Pi OS Lite (64-bit) image whose root partition
is encrypted with LUKS2. At boot you unlock it either over SSH (dropbear in the
initramfs asks for the passphrase straight away) or with a keyboard attached to
the Pi. Configure once, build, flash, boot, unlock, log in. No setup steps on
the Pi.

Made for a headless Raspberry Pi 4 booting from a USB SSD over Ethernet.

The previous version (Raspberry Pi OS Bullseye) is available as tag [`v1`](../../tree/v1).

## What you get

- Root partition encrypted with LUKS2, Adiantum cipher (fast on CPUs without
  AES instructions, like the Pi 4), Argon2id key derivation.
- One password for the disk, the user and root, asked once during the build.
- Unlocking over SSH on a separate port: connecting shows the passphrase prompt
  immediately. The unlock server allows nothing else (no shell, no forwarding,
  no password logins).
- Unlocking with a local keyboard, using your keyboard layout.
- The partition, LUKS container and file system grow to fill the disk on first
  boot without a reboot.
- User with passwordless sudo and your SSH keys; password login over SSH also
  allowed; root can only log in locally.
- Automatic security updates (no automatic reboots), persistent journal capped
  at 500 MB, optional TRIM, Wi-Fi and Bluetooth turned off, cloud-init and the
  first-boot user wizard disabled.

## Requirements

A Linux machine to build on, with `cryptsetup`, `rsync`, `xz`, `curl` and
`sfdisk` (package `fdisk`). Building on a 64-bit Raspberry Pi OS is easiest. On
x86 machines you additionally need `qemu-user-static` with binfmt support to run
the Pi's programs.

The build needs about 10 GB of free space.

## Build

```sh
cp config.example.sh config.sh
```

Edit `config.sh`: the base image URL and checksum, your SSH public keys, and
anything else you want to change. Then:

```sh
sudo ./build.sh
```

You're asked for the password once at the start; the rest runs unattended. At
the end the script checks that the boot partition contains a fresh initramfs
with everything needed to unlock (crypttab entry, dropbear, keys, keyboard
layout). If any of that is missing, the build fails instead of producing an
image you can't unlock.

## Flash and boot

Write the image to the SSD (replace `/dev/sdX`; double-check it's the right disk):

```sh
sudo dd if=raspios-encrypted.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Raspberry Pi Imager also works ("Use custom" image). Don't use its OS
customisation settings, since they would conflict with this setup.

Connect the SSD and Ethernet and power on the Pi. The Pi gets its address via
DHCP. Reserving a fixed address for it in your router is easiest, since you
need to know the address before the Pi has fully booted.

## Unlock and log in

```sh
ssh -p 2222 root@<pi-address>   # asks for the passphrase, then disconnects
ssh pi@<pi-address>             # the running system
```

Or type the passphrase on a keyboard attached to the Pi.

The unlock server has its own host key, which is different from the running
system's. Since it uses a different port, SSH stores them separately and won't
complain. The build prints the unlock server's fingerprints.

## Recovery

`chroot.sh` opens an image or a disk, mounts it and gives you a shell inside,
for example to inspect a built image or to repair the Pi's SSD from another
Linux machine:

```sh
sudo ./chroot.sh raspios-encrypted.img
sudo ./chroot.sh /dev/sdX
```

Recommended after the first boot (on the Pi):

- Back up the LUKS header, which holds the encrypted key; if it gets damaged the
  data is lost, even with the right passphrase. Store the file off the Pi:
  `sudo cryptsetup luksHeaderBackup /dev/sda2 --header-backup-file pi-luks-header.img`
- Keep a copy of the unlock SSH key somewhere other than your PC (e.g. your
  password manager). Without it you can only unlock with a local keyboard.

## Notes

- **TRIM** only works if the USB-SATA adapter supports it. Check with
  `lsblk --discard`: non-zero `DISC-GRAN`/`DISC-MAX` for the disk means it does.
  Some adapters need a udev rule setting `provisioning_mode` to `unmap`.
- **Changing unlock settings later** (keys, port): edit the files in
  `/etc/dropbear/initramfs/` on the Pi, then run `sudo update-initramfs -u -k all`.
- **Changing the password**: the disk passphrase and the login passwords are
  separate. For the disk: `sudo cryptsetup luksChangeKey /dev/sda2`. For the
  users: `passwd` and `sudo passwd root`.
- Unlocking takes a few seconds; the key derivation is deliberately slow to
  make guessing the passphrase expensive.
