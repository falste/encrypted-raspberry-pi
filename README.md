# Purpose
The goal of this project is to simplify setting up an encrypted raspberry pi that can be unlocked via ssh. This project generates an easy to use image with an initramfs running dropbear for unlocking, as well as an encrypted partition containing the normal raspberry pi file system.

The image is designed to be used exclusively via ssh and everything is set up accordingly.

See also: https://github.com/ViRb3/pi-encrypted-boot-ssh

# Warning
Ensure that you only connect one hard drive to the raspberry pi, as on the first boot the partitions are modified.

# Usage
After cloning the project, you should configure some settings. Start by copying the example settings:
```
cp -r config.example config
```

Modify the settings in the config folder accordingly. Make sure to specify the `authorized_keys` and `unlock_authorized_keys`.

Optionally, you can move files to custom_files, which will then be included in the image. For example a file in custom_files/home/pi/test.txt will end up in the respective location.

Once configured, generate the image by running
```
sudo ./generate.sh
```

Using
```
sudo ./chroot.sh
```
you can chroot into the decrypted system to inspect it.

You can now flash the output image onto a medium of your choosing (with a command like `sudo dd bs=1M if=raspios_out.img of=/dev/sdX conv=fdatasync  status=progress`) and connect it to the raspberry pi. You might need to enable usb booting for your raspberry pi.

Once started up, figure out your raspberry pis IP (through your router, for example) and connect to the `unlock_port` using an ssh key in the `unlock_authorized_keys`. Once connected, run the command `cryptroot-unlock` and enter the configured encryption password. The system will boot up fully and you will be able to connect via the normal ssh port (22) using an ssh key in the `authorized_keys`.

On first bootup, the system will reboot to increase the partitions size to 100%. You will therefore have to unlock the system multiple times.

# Adapting for systems other than the raspberry pi
* Remove the command `touch /boot/ssh`
* Remove `resize.sh` from system_files
* Remove the modifications to /boot/cmdline.txt
* Ensure you find another way to grow the partition/file system

# TODO
* Dockerize the image generation to make use of dockers caching as well as the more reliable build environment
* Enter password manually instead of reading it from file
* Separate the decryption password from the user password
