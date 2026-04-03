#!/bin/bash
# SSH bridge to PDU — called by ForceCommand in sshd_gateway
# Relays the terminal to the PDU using legacy SSH algorithms.
# Uses SSH_ASKPASS for password auth to avoid sshpass PTY interference.

PDU_IP_FILE="/var/run/pdu_ip"
PDU_USER="%%PDU_SSH_USER%%"
PDU_PORT="%%PDU_SSH_PORT%%"

if [ ! -f "$PDU_IP_FILE" ]; then
    echo "ERROR: PDU not found — no DHCP lease detected on eth1." >&2
    echo "Make sure the PDU is connected and powered on." >&2
    exit 1
fi

PDU_IP=$(cat "$PDU_IP_FILE")

export SSH_ASKPASS="/usr/local/bin/pdu-askpass.sh"
export SSH_ASKPASS_REQUIRE="force"

# Set the gateway PTY to raw mode so stdin/stdout pass through unmodified
stty raw -echo 2>/dev/null

exec ssh -tt \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    -o PubkeyAcceptedKeyTypes=+ssh-dss \
    -o HostKeyAlgorithms=+ssh-dss \
    -o KexAlgorithms=+diffie-hellman-group1-sha1 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=1 \
    -p "${PDU_PORT}" \
    "${PDU_USER}@${PDU_IP}"
