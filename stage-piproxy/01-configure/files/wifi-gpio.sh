#!/bin/bash
# WiFi GPIO jumper check — runs before NetworkManager
# Jumper present (pin pulled LOW) = WiFi ENABLED
# No jumper (pin floats HIGH via pull-up) = WiFi DISABLED

GPIO_CHIP="gpiochip0"
GPIO_PIN="%%WIFI_GPIO_PIN%%"
NM_STATE="/var/lib/NetworkManager/NetworkManager.state"

PIN_VALUE=$(gpioget --bias=pull-up "$GPIO_CHIP" "$GPIO_PIN" 2>/dev/null)

mkdir -p "$(dirname "$NM_STATE")"

if [ "$PIN_VALUE" = "0" ]; then
    echo "GPIO${GPIO_PIN} LOW — WiFi jumper detected, enabling WiFi"
    cat > "$NM_STATE" <<EOF
[main]
NetworkingEnabled=true
WirelessEnabled=true
EOF
else
    echo "GPIO${GPIO_PIN} HIGH — No WiFi jumper, disabling WiFi"
    cat > "$NM_STATE" <<EOF
[main]
NetworkingEnabled=true
WirelessEnabled=false
EOF
fi
