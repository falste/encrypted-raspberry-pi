# Purpose
The goal of this project is to simplify setting up an encrypted raspberry pi that can be unlocked via ssh. This project generates an easy to use image with an initramfs running dropbear for unlocking, as well as an encrypted partition containing the normal raspberry pi file system.

The image is designed to be used exclusively via ssh and everything is set up accordingly.

See also: https://github.com/ViRb3/pi-encrypted-boot-ssh

# Setup
After cloning the project, you should configure some settings. Start by copying the example settings:
```
cp -r config.example config
```

Modify the settings in the config folder accordingly. Make sure to specify the `authorized_keys` and `unlock_authorized_keys`. The keys in `authorized_keys` are used to log in into the `pi` user. The keys in `unlock_authorized_keys` are used for unlocking. The keys can be the same.

Optionally, you can move files to custom_files, which will then be included in the image. For example a file in custom_files/home/pi/test.txt will end up in the respective location. Additionally, you can add things to the custom_script.sh that will be executed on the target system once.

Once configured, generate the image by running
```
sudo ./generate.sh
```
A few warnings are to be expected.

Using
```
sudo ./chroot.sh
```
you can chroot into the decrypted system to inspect it.

You can now flash the output image onto a medium of your choosing (with a command like `sudo dd bs=1M if=raspios_out.img of=/dev/sdX conv=fdatasync  status=progress`) and connect it to the raspberry pi. You might need to enable usb booting for your raspberry pi.

# Usage
Once started up, figure out your raspberry pis IP (through your router, for example) and connect to the `unlock_port` using an ssh key in the `unlock_authorized_keys`. Once connected, run the command `cryptroot-unlock` and enter the configured encryption password. The system will boot up fully and you will be able to connect via the normal ssh port (22) using an ssh key in the `authorized_keys`.

On the first boot, you will need to unlock the system twice, as it reboots. You should also expand the encrypted partition and file system:
```
# find the drive containing the encrypted partition using:
lsblk

parted /dev/sdX --script resizepart2 100%
# there might be a reboot needed here
resize2fs /dev/mapper/crypted
# there might be a reboot needed here
```

The password of user pi is automatically removed. Feel free to change it or just use an encrypted key.

# TODO
* Automate resizing on first boot
* Dockerize the image generation to make use of dockers caching as well as the more reliable build environment
