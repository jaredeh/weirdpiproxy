#!/bin/bash -e
# Runs on the host with access to ${ROOTFS_DIR}

# --- Network configuration (static IPs for eth0 and eth1) ---
install -m 644 files/dhcpcd-static.conf "${ROOTFS_DIR}/etc/dhcpcd.conf"

# --- nginx ---
install -d "${ROOTFS_DIR}/etc/nginx/certs"
install -m 644 files/nginx-pdu.conf "${ROOTFS_DIR}/etc/nginx/sites-available/pdu.conf"
install -m 600 files/server.crt "${ROOTFS_DIR}/etc/nginx/certs/server.crt"
install -m 600 files/server.key "${ROOTFS_DIR}/etc/nginx/certs/server.key"
ln -sf /etc/nginx/sites-available/pdu.conf "${ROOTFS_DIR}/etc/nginx/sites-enabled/pdu.conf"
rm -f "${ROOTFS_DIR}/etc/nginx/sites-enabled/default"

# --- SSH gateway (eth0:22 → PDU) ---
install -m 644 files/sshd_gateway_config "${ROOTFS_DIR}/etc/ssh/sshd_config_gateway"
install -m 755 files/ssh-bridge.sh "${ROOTFS_DIR}/usr/local/bin/ssh-bridge.sh"
install -m 644 files/sshd-gateway.service "${ROOTFS_DIR}/etc/systemd/system/sshd-gateway.service"

# --- SSH management (all interfaces:2222 → Pi shell) ---
install -m 644 files/sshd_management_config "${ROOTFS_DIR}/etc/ssh/sshd_config"
install -m 644 files/sshd-management.service "${ROOTFS_DIR}/etc/systemd/system/sshd-management.service"

# --- dnsmasq (DHCP on eth1) ---
install -m 644 files/dnsmasq.conf "${ROOTFS_DIR}/etc/dnsmasq.conf"
install -m 755 files/pdu-lease-hook.sh "${ROOTFS_DIR}/usr/local/bin/pdu-lease-hook.sh"

# --- WiFi GPIO jumper ---
install -m 755 files/wifi-gpio.sh "${ROOTFS_DIR}/usr/local/bin/wifi-gpio.sh"
install -m 644 files/wifi-gpio.service "${ROOTFS_DIR}/etc/systemd/system/wifi-gpio.service"

# --- WiFi (wpa_supplicant) ---
install -m 600 files/wpa_supplicant.conf "${ROOTFS_DIR}/etc/wpa_supplicant/wpa_supplicant.conf"

# --- Firewall ---
install -m 644 files/nftables.conf "${ROOTFS_DIR}/etc/nftables.conf"
