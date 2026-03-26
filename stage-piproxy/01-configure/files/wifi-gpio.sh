#!/bin/bash
# WiFi GPIO jumper check
# If GPIO pin is LOW (jumper to GND present) = WiFi ENABLED
# If GPIO pin is HIGH (no jumper, internal pull-up) = WiFi DISABLED

GPIO_PIN="%%WIFI_GPIO_PIN%%"
PIN_VALUE=$(cat "/sys/class/gpio/gpio${GPIO_PIN}/value" 2>/dev/null)

if [ -z "$PIN_VALUE" ]; then
    echo "${GPIO_PIN}" > /sys/class/gpio/export 2>/dev/null
    sleep 0.1
    echo "in" > "/sys/class/gpio/gpio${GPIO_PIN}/direction"
    # Enable internal pull-up via pinctrl
    raspi-gpio set "${GPIO_PIN}" pu 2>/dev/null || true
    sleep 0.1
    PIN_VALUE=$(cat "/sys/class/gpio/gpio${GPIO_PIN}/value")
fi

if [ "$PIN_VALUE" = "0" ]; then
    echo "GPIO${GPIO_PIN} LOW — WiFi jumper detected, enabling WiFi"
    rfkill unblock wifi 2>/dev/null
    systemctl start wpa_supplicant@wlan0.service 2>/dev/null || true
    ip link set wlan0 up 2>/dev/null || true
    systemctl start dhcpcd@wlan0.service 2>/dev/null || \
        dhclient wlan0 2>/dev/null || true
else
    echo "GPIO${GPIO_PIN} HIGH — No WiFi jumper, disabling WiFi"
    ip link set wlan0 down 2>/dev/null || true
    systemctl stop wpa_supplicant@wlan0.service 2>/dev/null || true
    rfkill block wifi 2>/dev/null
fi
