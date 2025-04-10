#!/bin/bash

# --- Configuration (Variables used inside the container) ---
# Internal container paths
# Adjust path based on mounting /etc/letsencrypt from host
CONTAINER_CERT_DIR="/etc/letsencrypt/live/prostoy-fitnes.xyz"
CONTAINER_CONFIG_FILE="/app/config.json"
CONTAINER_LOG_DIR="/var/log/xray" # Match this with config.json log paths

echo "--- In-Container Xray Startup ---"

# Ensure log directory exists within the container (might be a volume mount)
# The user running the script (xray) needs write permission here.
# If HOST_LOG_DIR is mounted to CONTAINER_LOG_DIR, permissions need to be set on the host.
mkdir -p "${CONTAINER_LOG_DIR}"
# Attempt to ensure the 'xray' user can write (may fail if mounted from host with restrictive permissions)
chown xray:xray "${CONTAINER_LOG_DIR}" || echo "Warning: Could not chown ${CONTAINER_LOG_DIR}"

# Certificates are expected to be mounted read-only
# Check the updated path inside the container
if [ ! -f "${CONTAINER_CERT_DIR}/fullchain.pem" ] || [ ! -f "${CONTAINER_CERT_DIR}/privkey.pem" ]; then
    echo "ERROR: Let's Encrypt certificates not found mounted at ${CONTAINER_CERT_DIR}/"
    echo "Ensure the /etc/letsencrypt volume is mounted correctly from the host."
    exit 1
fi
echo "Mounted certificates found."

# Metadata key for the UUID
UUID_METADATA_KEY="xray-uuid"

# Fetch UUID from instance metadata (Requires network access to metadata server)
echo "Fetching VLESS UUID from metadata key '${UUID_METADATA_KEY}'..."
RETRY_COUNT=0
MAX_RETRIES=5
SLEEP_TIME=2
VLESS_UUID=""
# Ensure curl is available (should be added in Dockerfile)
if ! command -v curl &> /dev/null; then
    echo "ERROR: curl command could not be found. Please install it in the Docker image."
    exit 1
fi

while [ -z "$VLESS_UUID" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # Use -f to fail silently on server errors, check exit code later maybe?
  VLESS_UUID=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${UUID_METADATA_KEY}" -H "Metadata-Flavor: Google")
  if [ -z "$VLESS_UUID" ]; then
    echo "Metadata key not found or empty, retrying (${RETRY_COUNT}/${MAX_RETRIES})..."
    sleep $SLEEP_TIME
    RETRY_COUNT=$((RETRY_COUNT+1))
  fi
done

if [ -z "$VLESS_UUID" ]; then
 echo "ERROR: Failed to fetch UUID from metadata key '${UUID_METADATA_KEY}' after ${MAX_RETRIES} retries."
 exit 1
fi
echo "UUID fetched successfully from metadata."

# Generate config.json dynamically inside the container's /app directory
echo "Generating ${CONTAINER_CONFIG_FILE}..."
cat << EOF > "${CONTAINER_CONFIG_FILE}"
{
  "log": {
    "access": "${CONTAINER_LOG_DIR}/access.log",
    "error": "${CONTAINER_LOG_DIR}/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 8000, // Internal port, will be mapped by docker run -p
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "minVersion": "1.3",
          "cipherSuites": "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
          "certificates": [
            {
              "certificateFile": "${CONTAINER_CERT_DIR}/fullchain.pem",
              "keyFile": "${CONTAINER_CERT_DIR}/privkey.pem"
            }
          ]
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true
        }
      }
    },
    {
      "port": 80, // Internal port for health check, map with docker run -p
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": 1, // Should not conflict, just used internally by dokodemo
        "network": "tcp"
      },
      "tag": "health",
      "listen": "0.0.0.0" // Listen on all interfaces inside container
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["health"],
        "outboundTag": "block"
      }
    ],
    "domainStrategy": "AsIs"
  }
}
EOF
echo "${CONTAINER_CONFIG_FILE} generated."

# Set permissions for the config file to be readable by the xray user
chmod 644 "${CONTAINER_CONFIG_FILE}"
chown xray:xray "${CONTAINER_CONFIG_FILE}" || echo "Warning: Could not chown ${CONTAINER_CONFIG_FILE}"


echo "--- Debug: Checking Config File Before Start ---"
ls -l "${CONTAINER_CONFIG_FILE}"
echo "--- Debug: Config File Contents --- "
cat "${CONTAINER_CONFIG_FILE}"
echo "--- End Debug --- "
sleep 2 # Short pause just in case

echo "--- Starting Xray ---"
# Use exec to replace the shell process with the xray process
exec xray run -config "${CONTAINER_CONFIG_FILE}"

# --- Script End --- (exec means this line is never reached)