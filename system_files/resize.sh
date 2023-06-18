parted /dev/sda --script resizepart 2 100%
sed -i 's/ \.\/resize\.sh$//' /boot/cmdline.txt
rm /resize.sh
reboot now
