parted /dev/sda --script resizepart 2 100%
resize2fs /dev/mapper/crypted

systemctl disable resize.service
rm /etc/systemd/system/resize.service
reboot now
