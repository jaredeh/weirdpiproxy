#!/bin/bash

# Find the directory of this script and change to it
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"
source $SCRIPT_DIR/../.env

function help() {
    echo "Usage: $0 [--generate]"
    exit 1
}

# Load variables
CONFIG_FILE="${SCRIPT_DIR}/../config.yml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config.yml file not found: $CONFIG_FILE"
    exit 1
fi

function check_vault() {
    for var in crt key filename domain; do
        tempvar=$(yq -r ".vault_selfsignedcert_${var}" "$CONFIG_FILE")
        if [ -z "$tempvar" ]; then
            echo "Error: vault_selfsignedcert_${var} not found in $CONFIG_FILE"
            exit 1
        fi
        eval "vault_selfsignedcert_${var}=\"$tempvar\""
    done
}

# Parse command line arguments
COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --generate|--genca|--uploadca|--downloadca)
            if [[ -n "$COMMAND" ]]; then
                echo "Only one of --generate, --genca, --uploadca, --downloadca can be specified."
                echo ""
                help
            fi
            COMMAND="${1#--}"
            shift
            ;;
        --domain)
            vault_selfsignedcert_domain="$2"
            shift
            shift
            ;;
        --hostname)
            GENHOSTNAME=$2
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

function generate_ca() {
    echo "Generating CA for $vault_selfsignedcert_domain..."
    cd $SCRIPT_DIR
    check_vault

    if [ -f "./$vault_selfsignedcert_domain.ca.key" ] || [ -f "./$vault_selfsignedcert_domain.ca.crt" ]; then
        echo "CA for $vault_selfsignedcert_domain already exist."
        echo "Do you want to overwrite them? (y/n)"
        read -r overwrite
        if [ "$overwrite" == "y" ]; then
            echo "Overwriting CA..."
            rm -f "./$vault_selfsignedcert_domain.ca.key"
            rm -f "./$vault_selfsignedcert_domain.ca.crt"
        else
            echo "Not overwriting CA. Exiting."
            exit 1
        fi
    fi
    mkdir -p ./certificateauthority
    cd ./certificateauthority
    # Generate the self-signed root CA
    openssl req -x509 -newkey rsa:4096 -keyout $vault_selfsignedcert_domain.ca.key -out $vault_selfsignedcert_domain.ca.crt -days 3650 -nodes -subj "/CN=$vault_selfsignedcert_domain"
    cd $SCRIPT_DIR
}

# function upload_ca() {
#     cd $SCRIPT_DIR
#     check_vault

#     echo "Uploading CA $vault_selfsignedcert_domain to openbao..."
#     if [ ! -f "./$vault_selfsignedcert_domain.ca.key" ] || [ ! -f "./$vault_selfsignedcert_domain.ca.crt" ]; then
#         echo "CA does not exist. Generating it first."
#         generate_ca
#     fi

#     # Ensure the KV secrets engine mount exists
#     local KV_MOUNT="${vault_selfsignedcert_crt%%/*}"
#     if ! bao secrets list -format=json | grep -q "\"${KV_MOUNT}/\""; then
#         echo "Enabling KV secrets engine at '${KV_MOUNT}/'..."
#         bao secrets enable -path="${KV_MOUNT}" kv
#     fi

#     local CRT_STR=$(cat $SCRIPT_DIR/$vault_selfsignedcert_domain.ca.crt)
#     local KEY_STR=$(cat $SCRIPT_DIR/$vault_selfsignedcert_domain.ca.key)

#     # Upload the CA data to openbao
#     bao write $vault_selfsignedcert_crt "string"="$CRT_STR"
#     bao write $vault_selfsignedcert_key "string"="$KEY_STR"
#     cd $SCRIPT_DIR
# }

function download_ca() {
    cd $SCRIPT_DIR
    check_vault

    echo "Downloading CA $vault_selfsignedcert_domain from openbao..."
    if [ -f "./$vault_selfsignedcert_domain.ca.key" ] || [ -f "./$vault_selfsignedcert_domain.ca.crt" ]; then
        echo "CA for $vault_selfsignedcert_domain already exist."
        echo "Do you want to overwrite them? (y/n)"
        read -r overwrite
        if [ "$overwrite" == "y" ]; then
            echo "Overwriting CA..."
            rm -f "./$vault_selfsignedcert_domain.ca.key"
            rm -f "./$vault_selfsignedcert_domain.ca.crt"
        else
            echo "Not overwriting CA. Exiting."
            exit 1
        fi
    fi
    mkdir -p ./certificateauthority
    cd ./certificateauthority
    bao kv get -field=string kv/$vault_selfsignedcert_crt > $vault_selfsignedcert_domain.ca.crt
    bao kv get -field=string kv/$vault_selfsignedcert_key > $vault_selfsignedcert_domain.ca.key
    cd $SCRIPT_DIR
}

function generate_server_keys() {
    cd $SCRIPT_DIR
    check_vault

    # 1. Capture the input string
    INPUT_URLS="$1"
    if [ -z "$INPUT_URLS" ]; then
        echo "Error: No URLs provided."
        return 1
    fi

    # 2. Extract the first URL for the filename/Primary CN
    # This takes everything before the first comma
    PRIMARY_URL="${INPUT_URLS%%,*}"
    
    # 3. Format the SAN string
    # We replace every comma with ",DNS:" and prepend "DNS:" to the start
    SAN_STRING="DNS:${INPUT_URLS//,/ ,DNS:}"

    echo "Generating keys for Primary: $PRIMARY_URL"
    echo "Additional SANs: $SAN_STRING"

    # Check for existing keys
    if [ -f "./keys/$PRIMARY_URL.key" ]; then
        echo "Keys for $PRIMARY_URL already exist. Overwrite? (y/n)"
        read -r overwrite
        [[ "$overwrite" != "y" ]] && { echo "Exiting."; return 1; }
        rm -f "./keys/${PRIMARY_URL}.*"
    fi

    mkdir -p ./keys && cd ./keys

    # Generate Private Key
    openssl genrsa -out "$PRIMARY_URL.key" 4096

    # Generate CSR
    openssl req -new -key "$PRIMARY_URL.key" -out "$PRIMARY_URL.csr" \
        -subj "/CN=$PRIMARY_URL" \
        -addext "subjectAltName=$SAN_STRING"

    # Sign the certificate
    openssl x509 -req -in "$PRIMARY_URL.csr" \
      -CA ../certificateauthority/$vault_selfsignedcert_domain.ca.crt \
      -CAkey ../certificateauthority/$vault_selfsignedcert_domain.ca.key \
      -CAcreateserial -out "$PRIMARY_URL.crt" -days 3650 -sha256 \
      -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=$SAN_STRING")

    # Finalize
    cat "$PRIMARY_URL.crt" ../certificateauthority/$vault_selfsignedcert_domain.ca.crt > "$PRIMARY_URL.fullchain.crt"
    rm "$PRIMARY_URL.csr"
    cd ..
}

if [ "$COMMAND" == "genca" ]; then
    generate_ca
elif [ "$COMMAND" == "uploadca" ]; then
    upload_ca
elif [ "$COMMAND" == "downloadca" ]; then
    download_ca
elif [ "$COMMAND" == "generate" ]; then
    if [ -z "$GENHOSTNAME" ]; then
        echo "Please specify a hostname with --hostname."
        echo ""
        help
        exit 1
    fi
    generate_server_keys $GENHOSTNAME
else
    help
fi
