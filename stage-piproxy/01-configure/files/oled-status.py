#!/usr/bin/env python3
"""OLED status display for PiProxy — 128x64 SSD1306 over I2C."""

import subprocess
import time

from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306
from luma.core.render import canvas
from PIL import ImageFont

REFRESH_INTERVAL = 5  # seconds per page
INTERFACES = ["eth0", "eth1", "wlan0"]
PDU_IP_FILE = "/var/run/pdu_ip"
SERVICES = [
    ("sshd-mgmt", "ssh"),       # default ssh.service = management sshd
    ("sshd-gw", "sshd-gateway"),
    ("nginx", "nginx"),
    ("dnsmasq", "dnsmasq"),
]

# Attempt to use a small monospace font; fall back to default
try:
    FONT = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 9)
except OSError:
    FONT = ImageFont.load_default()


def get_iface_info(iface):
    """Return (state, ip) for a network interface using NetworkManager."""
    try:
        out = subprocess.check_output(
            ["nmcli", "-t", "-f", "GENERAL.STATE,IP4.ADDRESS", "device", "show", iface],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "down", ""

    state = ""
    ip = ""
    for line in out.strip().splitlines():
        if line.startswith("GENERAL.STATE:"):
            raw = line.split(":", 1)[1].strip()
            # e.g. "100 (connected)" → "up"
            if "connected" in raw.lower():
                state = "up"
            elif "unavailable" in raw.lower() or "unmanaged" in raw.lower():
                state = "down"
            else:
                state = raw.split("(")[-1].rstrip(")") if "(" in raw else raw
        elif line.startswith("IP4.ADDRESS"):
            ip = line.split(":", 1)[1].strip()
    return state or "down", ip


def get_vlans():
    """Return list of VLAN sub-interfaces on eth0."""
    try:
        out = subprocess.check_output(
            ["ip", "-br", "link", "show", "type", "vlan"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    vlans = []
    for line in out.strip().splitlines():
        name = line.split()[0]
        if name.startswith("eth0."):
            vlans.append(name)
    return vlans


def get_pdu_status():
    """Return PDU IP from the lease file, or None."""
    try:
        with open(PDU_IP_FILE) as f:
            ip = f.read().strip()
            return ip if ip else None
    except FileNotFoundError:
        return None


def get_service_status(unit):
    """Return 'running', 'stopped', or 'failed' for a systemd unit."""
    try:
        out = subprocess.check_output(
            ["systemctl", "is-active", unit],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except subprocess.CalledProcessError as exc:
        out = exc.output.strip() if exc.output else "dead"
    if out == "active":
        return "running"
    if out == "failed":
        return "failed"
    return "stopped"


def page_network():
    """Build lines for the network status page."""
    lines = ["-- Network --"]

    for iface in INTERFACES:
        state, ip = get_iface_info(iface)
        label = iface.replace("wlan0", "wlan")
        lines.append(f"{label}: {ip if ip else state}")

    for vlan in get_vlans():
        state, ip = get_iface_info(vlan)
        lines.append(f"  {vlan}: {ip if ip else state}")

    pdu_ip = get_pdu_status()
    lines.append(f"pdu: {pdu_ip if pdu_ip else 'offline'}")

    return lines


def page_services():
    """Build lines for the services status page."""
    lines = ["-- Services --"]
    for label, unit in SERVICES:
        status = get_service_status(unit)
        marker = "+" if status == "running" else ("!" if status == "failed" else "-")
        lines.append(f" {marker} {label}: {status}")
    return lines


PAGES = [page_network, page_services]


def draw(device, page_fn):
    """Draw one page of status info."""
    lines = page_fn()
    with canvas(device) as draw_ctx:
        y = 0
        for line in lines:
            draw_ctx.text((0, y), line, fill="white", font=FONT)
            y += 10


def main():
    serial = i2c(port=1, address=0x3C)
    device = ssd1306(serial, width=128, height=64)
    device.contrast(200)

    page_idx = 0
    while True:
        try:
            draw(device, PAGES[page_idx])
        except Exception as exc:
            print(f"oled-status: draw error: {exc}")
        page_idx = (page_idx + 1) % len(PAGES)
        time.sleep(REFRESH_INTERVAL)


if __name__ == "__main__":
    main()
