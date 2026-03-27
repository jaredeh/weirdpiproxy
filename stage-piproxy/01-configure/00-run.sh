#!/bin/bash -e
# Runs on the host with access to ${ROOTFS_DIR}

# --- Network configuration (NetworkManager connections) ---
install -d "${ROOTFS_DIR}/etc/NetworkManager/system-connections"
install -m 600 files/eth0.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/eth0-static.nmconnection"
install -m 600 files/eth1.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/eth1-static.nmconnection"
# Install any VLAN connection files
for f in files/vlan-*.nmconnection; do
    [ -f "$f" ] && install -m 600 "$f" "${ROOTFS_DIR}/etc/NetworkManager/system-connections/$(basename "$f")"
done

# --- nginx ---
install -d "${ROOTFS_DIR}/etc/systemd/system/nginx.service.d"
install -m 644 files/nginx-restart-override.conf "${ROOTFS_DIR}/etc/systemd/system/nginx.service.d/override.conf"
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
# Overwrites default sshd_config — the default ssh.service uses this
install -m 644 files/sshd_management_config "${ROOTFS_DIR}/etc/ssh/sshd_config"

# --- dnsmasq (DHCP on eth1) ---
install -m 644 files/dnsmasq.conf "${ROOTFS_DIR}/etc/dnsmasq.conf"
install -m 755 files/pdu-lease-hook.sh "${ROOTFS_DIR}/usr/local/bin/pdu-lease-hook.sh"

# --- WiFi GPIO jumper ---
install -m 755 files/wifi-gpio.sh "${ROOTFS_DIR}/usr/local/bin/wifi-gpio.sh"
install -m 644 files/wifi-gpio.service "${ROOTFS_DIR}/etc/systemd/system/wifi-gpio.service"

# --- WiFi (NetworkManager connection) ---
install -m 600 files/wifi.nmconnection "${ROOTFS_DIR}/etc/NetworkManager/system-connections/piproxy-wifi.nmconnection"

# --- OLED status display ---
install -m 755 files/oled-status.py "${ROOTFS_DIR}/usr/local/bin/oled-status.py"
install -m 644 files/oled-status.service "${ROOTFS_DIR}/etc/systemd/system/oled-status.service"

# Enable I2C interface
grep -qxF "dtparam=i2c_arm=on" "${ROOTFS_DIR}/boot/firmware/config.txt" 2>/dev/null \
    || echo "dtparam=i2c_arm=on" >> "${ROOTFS_DIR}/boot/firmware/config.txt"
grep -qxF "i2c-dev" "${ROOTFS_DIR}/etc/modules" 2>/dev/null \
    || echo "i2c-dev" >> "${ROOTFS_DIR}/etc/modules"

# --- Firewall ---
install -m 644 files/nftables.conf "${ROOTFS_DIR}/etc/nftables.conf"

cp "${ROOTFS_DIR}/etc/nginx/sites-available/pdu.conf"  files/flarp.conf