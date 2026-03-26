# PiProxy

Vibecoded tools to create a Raspberry Pi 2 image that acts as a secure proxy in front of an Eaton EMAT10-10 PDU (or similar legacy devices with outdated TLS/SSH).

## Why

The Eaton EMAT10-10 PDU has firmware that uses deprecated TLS/SSL versions (rejected by modern browsers) and SSH algorithms (ssh-dss, diffie-hellman-group1-sha1) that require special client configuration. PiProxy sits between your network and the PDU, presenting modern TLS and SSH so you can use Chrome and standard SSH clients without any special configuration.

## How It Works

```
                        ┌──────────────────────────┐
                        │      Raspberry Pi 2      │
[Your Network]          │                          │          [PDU]
  ─────────────────────►│ eth0 ──── nginx ────► eth1 ──────► EMAT10-10
  HTTPS (modern TLS)    │  :443    (reverse      :static     (legacy TLS)
                        │          proxy)         │
  ─────────────────────►│ eth0 ──── sshd ─────► eth1 ──────►
  SSH (modern crypto)   │  :22    (ForceCommand)  │          (ssh-dss)
                        │                          │
  ─────────────────────►│ :2222   Pi management   │
  SSH (management)      │          shell          │
                        │                          │
  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─►│ wlan0   Pi management   │
  WiFi (management)     │  :2222   shell          │
                        └──────────────────────────┘
```

- **eth0** (built-in gigabit): Client-facing, static IP. Serves HTTPS and SSH.
- **eth1** (USB gigabit dongle): PDU-facing, static IP. Runs a DHCP server.
- **wlan0** (built-in WiFi): Management access. DHCP client. Can be disabled with a GPIO jumper.

### HTTPS Proxy

nginx terminates modern TLS using your certificate on eth0:443, then reverse-proxies to the PDU over its legacy HTTPS. The PDU's IP is discovered automatically from the DHCP lease (it's the only device on eth1). Your browser connects to the Pi — Chrome works fine.

### SSH Gateway

A dedicated `sshd` on eth0:22 authenticates you with modern keys, then transparently bridges to the PDU using legacy SSH algorithms and stored credentials. You just `ssh admin@<pi-ip>` and get the PDU terminal.

### Pi Management

A second `sshd` on port 2222 (eth0 and wlan0) gives you a normal shell on the Pi for maintenance:

```bash
ssh -p 2222 admin@<eth0-ip>
ssh admin@<wlan0-ip>          # port 22 on WiFi is redirected to management
```

### WiFi GPIO Jumper

A physical jumper on GPIO17 controls WiFi:
- **Jumper present** (GPIO17 pulled to GND): WiFi enabled
- **No jumper** (GPIO17 floats HIGH via pull-up): WiFi disabled

This lets you physically disable the WiFi interface for security.

## Prerequisites

- Docker (pi-gen builds inside Docker)
- `yq` (YAML parser for bash — `sudo apt install yq` or `brew install yq`)
- `git`

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/jaredeh/weirdpiproxy.git
cd weirdpiproxy

# 2. Create your config
cp config.yml.example config.yml
# Edit config.yml with your IPs, WiFi credentials, PDU credentials, etc.

# 3. Add your TLS certificate
cp /path/to/your/cert.crt certs/server.crt
cp /path/to/your/cert.key certs/server.key

# 4. Build the image
./build.sh

# 5. Flash to SD card
dd if=piproxy-YYYYMMDD.img of=/dev/sdX bs=4M status=progress
```

## Configuration

All settings are in `config.yml`. See `config.yml.example` for the full template with descriptions.

| Setting | Description |
|---------|-------------|
| `eth0_ip` / `eth0_netmask` | Client-facing static IP |
| `eth1_ip` / `eth1_netmask` | PDU-facing static IP |
| `dhcp_range_*` | DHCP range served on eth1 |
| `wifi_ssid` / `wifi_password` | WiFi network for management |
| `pi_username` / `pi_password` | Pi login credentials |
| `tls_cert_path` / `tls_key_path` | Your TLS certificate files |
| `pdu_ssh_user` / `pdu_ssh_password` | PDU SSH credentials |
| `wifi_gpio_pin` | GPIO pin for WiFi jumper (default: 17) |

## Network Ports

| Interface | Port | Service |
|-----------|------|---------|
| eth0 | 443 | HTTPS reverse proxy to PDU |
| eth0 | 22 | SSH gateway to PDU |
| eth0 | 2222 | Pi management SSH |
| wlan0 | 22 | Pi management SSH (redirected to 2222) |

## Security

- The firewall (nftables) defaults to deny. Only the listed ports are open on their respective interfaces.
- No IP forwarding or routing between networks — all proxying is at the application layer.
- PDU credentials are stored on the Pi's filesystem, accessible only to root.
- WiFi can be physically disabled with the GPIO jumper.

## Hardware

- Raspberry Pi 2 Model B
- USB Gigabit Ethernet adapter (for the PDU-facing network)
- SD card (8GB+)
- Optional: 2-pin jumper for GPIO17 WiFi toggle
