#!/bin/bash -e
# Runs inside the chroot — enable/disable services

# Default ssh.service uses /etc/ssh/sshd_config (our management config) — keep it enabled
# Add our gateway sshd as a separate service
systemctl enable sshd-gateway.service
systemctl enable nginx.service
systemctl enable dnsmasq.service
systemctl enable nftables.service
systemctl enable wifi-gpio.service
pip3 install --break-system-packages luma.oled
systemctl enable oled-status.service
