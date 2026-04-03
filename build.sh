#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
PIGEN_DIR="${SCRIPT_DIR}/pi-gen"
STAGE_DIR="${SCRIPT_DIR}/stage-piproxy"
BUILD_STAGE_DIR="${SCRIPT_DIR}/build/stage-piproxy"

# --- Dependency checks ---
check_dependencies() {
    local missing=()
    for cmd in git docker yq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if ! command -v qemu-arm &>/dev/null && ! command -v qemu-arm-static &>/dev/null; then
        missing+=("qemu-user-static")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required tools: ${missing[*]}"
        echo "Install them and try again."
        exit 1
    fi
}

# --- Config handling ---
ensure_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No config.yml found."
        read -rp "Create one from config.yml.example? [Y/n] " answer
        if [[ "$answer" =~ ^[Nn] ]]; then
            echo "Cannot continue without config.yml. Exiting."
            exit 1
        fi
        cp "${SCRIPT_DIR}/config.yml.example" "$CONFIG_FILE"
        echo "Created config.yml — please edit it with your values, then re-run this script."
        exit 0
    fi
}

# --- Read config values ---
cfg() {
    yq -r ".$1" "$CONFIG_FILE"
}

netmask_to_cidr() {
    local mask="$1"
    local cidr=0
    for octet in $(echo "$mask" | tr '.' ' '); do
        while [ "$octet" -gt 0 ]; do
            cidr=$((cidr + (octet & 1)))
            octet=$((octet >> 1))
        done
    done
    echo "$cidr"
}

load_config() {
    ETH0_IP=$(cfg eth0_ip)
    ETH0_NETMASK=$(cfg eth0_netmask)
    ETH0_CIDR=$(netmask_to_cidr "$ETH0_NETMASK")
    ETH1_IP=$(cfg eth1_ip)
    ETH1_NETMASK=$(cfg eth1_netmask)
    ETH1_CIDR=$(netmask_to_cidr "$ETH1_NETMASK")
    DHCP_RANGE_START=$(cfg dhcp_range_start)
    DHCP_RANGE_END=$(cfg dhcp_range_end)
    DHCP_LEASE_TIME=$(cfg dhcp_lease_time)
    WIFI_SSID=$(cfg wifi_ssid)
    WIFI_PASSWORD=$(cfg wifi_password)
    WIFI_COUNTRY=$(cfg wifi_country)
    PI_USERNAME=$(cfg pi_username)
    PI_PASSWORD=$(cfg pi_password)
    TLS_CERT_PATH=$(cfg tls_cert_path)
    TLS_KEY_PATH=$(cfg tls_key_path)
    PDU_HTTPS_PORT=$(cfg pdu_https_port)
    PDU_SSH_USER=$(cfg pdu_ssh_user)
    PDU_SSH_PASSWORD=$(cfg pdu_ssh_password)
    PDU_SSH_PORT=$(cfg pdu_ssh_port)
    WIFI_GPIO_PIN=$(cfg wifi_gpio_pin)
}

# --- Validate config ---
validate_config() {
    local errors=()

    if [ ! -f "${SCRIPT_DIR}/${TLS_CERT_PATH}" ]; then
        errors+=("TLS cert not found: ${TLS_CERT_PATH}")
    fi
    if [ ! -f "${SCRIPT_DIR}/${TLS_KEY_PATH}" ]; then
        errors+=("TLS key not found: ${TLS_KEY_PATH}")
    fi

    for var_name in ETH0_IP ETH1_IP PI_USERNAME PI_PASSWORD; do
        val="${!var_name}"
        if [ -z "$val" ] || [ "$val" = "null" ]; then
            errors+=("${var_name} is not set in config.yml")
        fi
    done

    if [ ${#errors[@]} -gt 0 ]; then
        echo "ERROR: Configuration validation failed:"
        for e in "${errors[@]}"; do
            echo "  - $e"
        done
        exit 1
    fi
}

# --- Template processing ---
process_templates() {
    echo "Processing templates..."
    rm -rf "$BUILD_STAGE_DIR"
    mkdir -p "$(dirname "$BUILD_STAGE_DIR")"
    cp -r "$STAGE_DIR" "$BUILD_STAGE_DIR"

    # Copy TLS cert/key into the build stage
    cp "${SCRIPT_DIR}/${TLS_CERT_PATH}" "${BUILD_STAGE_DIR}/01-configure/files/server.crt"
    cp "${SCRIPT_DIR}/${TLS_KEY_PATH}" "${BUILD_STAGE_DIR}/01-configure/files/server.key"

    # Generate VLAN config snippets
    local vlan_sshd="" vlan_nftables=""
    local vlan_count
    vlan_count=$(yq -r '.eth0_vlans | length // 0' "$CONFIG_FILE" 2>/dev/null || echo 0)

    if [ "$vlan_count" -gt 0 ]; then
        for i in $(seq 0 $((vlan_count - 1))); do
            local vid ip mask cidr
            vid=$(yq -r ".eth0_vlans[$i].id" "$CONFIG_FILE")
            ip=$(yq -r ".eth0_vlans[$i].ip" "$CONFIG_FILE")
            mask=$(yq -r ".eth0_vlans[$i].netmask" "$CONFIG_FILE")
            cidr=$(netmask_to_cidr "$mask")

            # Generate NM connection file for this VLAN
            cat > "${BUILD_STAGE_DIR}/01-configure/files/vlan-${vid}.nmconnection" <<VLANEOF
[connection]
id=eth0-vlan${vid}
type=vlan
autoconnect=true

[vlan]
parent=eth0
id=${vid}

[ipv4]
method=manual
addresses=${ip}/${cidr}

[ipv6]
method=disabled
VLANEOF

            vlan_sshd+="ListenAddress ${ip}\n"
            vlan_nftables+="        iifname \"eth0.${vid}\" tcp dport 80 accept\n"
            vlan_nftables+="        iifname \"eth0.${vid}\" tcp dport 443 accept\n"
            vlan_nftables+="        iifname \"eth0.${vid}\" tcp dport 22 accept\n"
            vlan_nftables+="        iifname \"eth0.${vid}\" tcp dport 2222 accept\n"
        done
    fi

    # Substitute all %%VARIABLE%% placeholders in build stage files
    local replacements=(
        "%%ETH0_IP%%:${ETH0_IP}"
        "%%ETH0_NETMASK%%:${ETH0_NETMASK}"
        "%%ETH0_CIDR%%:${ETH0_CIDR}"
        "%%ETH1_IP%%:${ETH1_IP}"
        "%%ETH1_NETMASK%%:${ETH1_NETMASK}"
        "%%ETH1_CIDR%%:${ETH1_CIDR}"
        "%%DHCP_RANGE_START%%:${DHCP_RANGE_START}"
        "%%DHCP_RANGE_END%%:${DHCP_RANGE_END}"
        "%%DHCP_LEASE_TIME%%:${DHCP_LEASE_TIME}"
        "%%WIFI_SSID%%:${WIFI_SSID}"
        "%%WIFI_PASSWORD%%:${WIFI_PASSWORD}"
        "%%WIFI_COUNTRY%%:${WIFI_COUNTRY}"
        "%%PDU_HTTPS_PORT%%:${PDU_HTTPS_PORT}"
        "%%PDU_SSH_USER%%:${PDU_SSH_USER}"
        "%%PDU_SSH_PASSWORD%%:${PDU_SSH_PASSWORD}"
        "%%PDU_SSH_PORT%%:${PDU_SSH_PORT}"
        "%%WIFI_GPIO_PIN%%:${WIFI_GPIO_PIN}"
    )

    find "$BUILD_STAGE_DIR" -type f | while read -r file; do
        for replacement in "${replacements[@]}"; do
            local placeholder="${replacement%%:*}"
            local value="${replacement#*:}"
            sed -i "s|${placeholder}|${value}|g" "$file"
        done
    done

    # Substitute VLAN placeholders (multiline content)
    local files_dir="${BUILD_STAGE_DIR}/01-configure/files"
    replace_placeholder() {
        local file="$1" placeholder="$2" content="$3"
        local tmpfile="${file}.tmp"
        awk -v pat="$placeholder" -v rep="$content" '{
            idx = index($0, pat)
            if (idx > 0) { printf "%s%s%s\n", substr($0,1,idx-1), rep, substr($0,idx+length(pat)) }
            else { print }
        }' "$file" > "$tmpfile" && mv "$tmpfile" "$file"
    }
    replace_placeholder "${files_dir}/sshd_gateway_config" "%%VLAN_SSHD_LISTEN%%" "$(echo -e "$vlan_sshd")"
    replace_placeholder "${files_dir}/nftables.conf" "%%VLAN_NFTABLES%%" "$(echo -e "$vlan_nftables")"
}

# --- pi-gen setup ---
setup_pigen() {
    if [ ! -d "$PIGEN_DIR" ]; then
        echo "Cloning pi-gen (bookworm branch)..."
        git clone --depth 1 --branch bookworm https://github.com/RPi-Distro/pi-gen.git "$PIGEN_DIR"
    else
        echo "Updating pi-gen..."
        git -C "$PIGEN_DIR" pull --ff-only 2>/dev/null || true
    fi

    # Copy processed stage into pi-gen directory (Docker copies everything from there)
    rm -rf "${PIGEN_DIR}/stage-piproxy"
    cp -r "$BUILD_STAGE_DIR" "${PIGEN_DIR}/stage-piproxy"

    # Generate pi-gen config
    cat > "${PIGEN_DIR}/config" <<EOF
IMG_NAME=piproxy
RELEASE=bookworm
TARGET_HOSTNAME=piproxy
FIRST_USER_NAME=${PI_USERNAME}
FIRST_USER_PASS=${PI_PASSWORD}
ENABLE_SSH=1
DISABLE_FIRST_BOOT_USER_RENAME=1
WPA_COUNTRY=${WIFI_COUNTRY}
LOCALE_DEFAULT=en_US.UTF-8
KEYBOARD_KEYMAP=us
TIMEZONE_DEFAULT=UTC
STAGE_LIST="stage0 stage1 stage2 stage-piproxy"
DEPLOY_COMPRESSION=none
EOF

    # Skip stages 3-5 (desktop)
    for stage in stage3 stage4 stage5; do
        if [ -d "${PIGEN_DIR}/${stage}" ] && [ ! -f "${PIGEN_DIR}/${stage}/SKIP" ]; then
            touch "${PIGEN_DIR}/${stage}/SKIP"
        fi
    done

    # Ensure stage2 produces an image (we build on top of it)
    touch "${PIGEN_DIR}/stage2/SKIP_IMAGES"

    # Ensure our custom stage produces the final image
    rm -f "${PIGEN_DIR}/stage-piproxy/SKIP" "${PIGEN_DIR}/stage-piproxy/SKIP_IMAGES"
    touch "${PIGEN_DIR}/stage-piproxy/EXPORT_IMAGE"
}

# --- Build ---
run_build() {
    echo "Starting pi-gen build (this will take a while)..."

    # pi-gen looks for 'qemu-arm' but some distros only ship 'qemu-arm-static'
    if ! command -v qemu-arm &>/dev/null && command -v qemu-arm-static &>/dev/null; then
        mkdir -p "${SCRIPT_DIR}/build/bin"
        ln -sf "$(command -v qemu-arm-static)" "${SCRIPT_DIR}/build/bin/qemu-arm"
        export PATH="${SCRIPT_DIR}/build/bin:${PATH}"
    fi

    cd "$PIGEN_DIR"

    # Build using Docker (recommended)
    if command -v docker &>/dev/null; then
        CONTINUE=1 ./build-docker.sh
    else
        echo "Docker not found. Attempting native build (requires root)..."
        sudo ./build.sh
    fi

    # Copy output image
    local img_file
    img_file=$(find "${PIGEN_DIR}/deploy" -name "*.zip" -o -name "*.img.xz" -o -name "*.img" | head -n 1)
    if [ -n "$img_file" ]; then
        local ext="${img_file##*.}"
        local output_name="piproxy-$(date +%Y%m%d).${ext}"
        cp "$img_file" "${SCRIPT_DIR}/${output_name}"
        echo ""
        echo "========================================="
        echo "Build complete!"
        echo "Image: ${output_name}"
        if [[ "$ext" == "zip" ]]; then
            echo "Extract and flash: unzip ${output_name} && dd if=*.img of=/dev/sdX bs=4M status=progress"
        else
            echo "Flash with: dd if=${output_name} of=/dev/sdX bs=4M status=progress"
        fi
        echo "========================================="

        # Flash directly if a block device was specified
        if [ -n "${FLASH_DEV:-}" ]; then
            echo ""
            echo "Flashing to ${FLASH_DEV}..."
            sudo dd if="${SCRIPT_DIR}/${output_name}" of="${FLASH_DEV}" bs=512k oflag=direct status=progress
            sync
            echo "Flash complete."
        fi
    else
        echo "ERROR: Build completed but no image found in pi-gen/deploy/"
        exit 1
    fi
}

# --- Clean ---
clean() {
    echo "Cleaning build artifacts..."
    rm -rf "${SCRIPT_DIR}/build"
    rm -rf "${SCRIPT_DIR}/pi-gen"
    rm -f "${SCRIPT_DIR}"/piproxy-*.img "${SCRIPT_DIR}"/piproxy-*.zip "${SCRIPT_DIR}"/piproxy-*.xz
    docker rm -v pigen_work 2>/dev/null || true
    echo "Done."
}

# --- Distclean ---
distclean() {
    clean
    echo "Removing user config and certs..."
    rm -f "${SCRIPT_DIR}/config.yml"
    rm -f "${SCRIPT_DIR}"/certs/*.crt "${SCRIPT_DIR}"/certs/*.key "${SCRIPT_DIR}"/certs/*.pem
    echo "Done."
}

# --- Mount ---
mount_image() {
    local img
    img=$(ls -t "${SCRIPT_DIR}"/piproxy-*.img 2>/dev/null | head -n 1)
    if [ -z "$img" ]; then
        echo "ERROR: No piproxy-*.img found"
        exit 1
    fi

    local mnt="${SCRIPT_DIR}/mnt"
    mkdir -p "$mnt"

    local loop
    loop=$(sudo losetup --find --show --partscan "$img")
    echo "Attached $img to $loop"

    # Mount the root partition (partition 2)
    sudo mount "${loop}p2" "$mnt"
    sudo mount "${loop}p1" "$mnt/boot/firmware"
    echo "Mounted at $mnt"
    echo "To unmount: $0 umount"
}

# --- Unmount ---
umount_image() {
    local mnt="${SCRIPT_DIR}/mnt"
    if ! mountpoint -q "$mnt" 2>/dev/null; then
        echo "ERROR: $mnt is not mounted"
        exit 1
    fi

    sudo umount "$mnt/boot/firmware" 2>/dev/null || true
    sudo umount "$mnt"

    # Detach any loop devices pointing at our images
    for loop in $(losetup -j "${SCRIPT_DIR}"/piproxy-*.img 2>/dev/null | cut -d: -f1); do
        sudo losetup -d "$loop"
        echo "Detached $loop"
    done
    echo "Unmounted $mnt"
}

# --- Main ---
main() {
    case "${1:-}" in
        clean) clean; exit 0 ;;
        distclean) distclean; exit 0 ;;
        mount) mount_image; exit 0 ;;
        umount|unmount) umount_image; exit 0 ;;
    esac

    # Check for block device argument
    if [ -n "${1:-}" ]; then
        if [ -b "$1" ]; then
            FLASH_DEV="$1"
        else
            echo "ERROR: $1 is not a block device"
            exit 1
        fi
    fi

    echo "=== PiProxy Image Builder ==="
    echo ""

    check_dependencies
    ensure_config
    load_config
    validate_config
    process_templates
    setup_pigen
    run_build
}

main "$@"
