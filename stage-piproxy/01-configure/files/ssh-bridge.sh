#!/bin/bash
# SSH bridge to Eaton PDU — called by ForceCommand in sshd_gateway
# Connects to the PDU using legacy SSH algorithms and relays the terminal.

PDU_IP_FILE="/var/run/pdu_ip"
PDU_USER="%%PDU_SSH_USER%%"
PDU_PASS="%%PDU_SSH_PASSWORD%%"
PDU_PORT="%%PDU_SSH_PORT%%"

if [ ! -f "$PDU_IP_FILE" ]; then
    echo "ERROR: PDU not found — no DHCP lease detected on eth1." >&2
    echo "Make sure the PDU is connected and powered on." >&2
    exit 1
fi

PDU_IP=$(cat "$PDU_IP_FILE")

exec sshpass -p "${PDU_PASS}" ssh -tt \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PubkeyAcceptedKeyTypes=+ssh-dss \
    -o HostKeyAlgorithms=+ssh-dss \
    -o KexAlgorithms=+diffie-hellman-group1-sha1 \
    -p "${PDU_PORT}" \
    "${PDU_USER}@${PDU_IP}"
