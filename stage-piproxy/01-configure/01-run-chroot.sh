#!/bin/bash -e
# Runs inside the chroot — enable/disable services

# Disable the default sshd (we run our own two instances)
systemctl disable ssh.service 2>/dev/null || true

# Enable our services
systemctl enable sshd-gateway.service
systemctl enable sshd-management.service
systemctl enable nginx.service
systemctl enable dnsmasq.service
systemctl enable nftables.service
systemctl enable wifi-gpio.service
