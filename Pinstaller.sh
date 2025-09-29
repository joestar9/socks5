#!/usr/bin/env bash
# install-psiphon-with-systemd.sh
# Ubuntu 24 — clears previous installation, recreates /etc/psiphon/{CC} folders,
# places binary+per-folder config (with sequential SOCKS ports and EgressRegion),
# creates systemd template and an override that allows writes to /etc/psiphon/%i,
# then enables+starts instances.
#
# CHANGES (per your request):
# - LocalHttpProxyPort will NOT be set or created. The script will REMOVE that
#   field from the config if present.
# - Only LocalSocksProxyPort is assigned (sequential from 7001).
# - Script wipes previous /etc/psiphon/* before installing.

set -euo pipefail

BASE_DIR="/etc/psiphon"
COUNTRIES=( "AT" "BE" "BG" "CA" "CH" "CZ" "DE" "DK" "EE" "ES" "FI" "FR" "GB" "HU" "IE" "IN" "IT" "JP" "LV" "NL" "NO" "PL" "RO" "RS" "SE" "SG" "SK" "US" )
BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
CONFIG_URL="https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/psiphon.config"
BIN_NAME="psiphon-tunnel-core-x86_64"
CONFIG_NAME="psiphon.config"

# Port range for SOCKS only
SOCKS_BASE=7001

NUM_COUNTRIES=${#COUNTRIES[@]}
if [ $NUM_COUNTRIES -gt 50 ]; then
  echo "Error: script assumes <=50 countries (SOCKS port range 7001-7050)." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (use sudo)." >&2
  exit 1
fi

# Ensure dependencies
if ! command -v curl >/dev/null 2>&1; then
  apt-get update
  apt-get install -y curl
fi
if ! command -v jq >/dev/null 2>&1; then
  apt-get update
  apt-get install -y jq
fi

# Stop and disable existing instances, then remove old files
echo "Stopping existing psiphon services (if any)..."
for cc in "${COUNTRIES[@]}"; do
  svc="psiphon@${cc}.service"
  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true
done

# Remove previous installation contents (explicit user request)
if [ -d "$BASE_DIR" ]; then
  echo "Removing previous contents of $BASE_DIR ..."
  rm -rf "$BASE_DIR"/*
else
  mkdir -p "$BASE_DIR"
fi
chmod 755 "$BASE_DIR"

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Downloading binary to temporary directory..."
if ! curl -fSL "$BIN_URL" -o "$TMPDIR/$BIN_NAME"; then
  echo "Failed to download binary from $BIN_URL" >&2
  exit 1
fi
chmod +x "$TMPDIR/$BIN_NAME"

echo "Downloading config to temporary directory..."
if ! curl -fSL "$CONFIG_URL" -o "$TMPDIR/$CONFIG_NAME"; then
  echo "Failed to download config from $CONFIG_URL" >&2
  exit 1
fi

# Prepare per-country folders and generate per-folder config
for idx in "${!COUNTRIES[@]}"; do
  cc=${COUNTRIES[$idx]}
  TARGET_DIR="$BASE_DIR/$cc"
  mkdir -p "$TARGET_DIR"

  # copy binary
  cp -f "$TMPDIR/$BIN_NAME" "$TARGET_DIR/$BIN_NAME"
  chmod 755 "$TARGET_DIR/$BIN_NAME"
  chown root:root "$TARGET_DIR/$BIN_NAME"

  # compute socks port
  socks_port=$((SOCKS_BASE + idx))

  # modify config: remove LocalHttpProxyPort (if present), set LocalSocksProxyPort and EgressRegion
  if ! jq --argjson socks "$socks_port" --arg region "$cc" \
         'del(.LocalHttpProxyPort) | .LocalSocksProxyPort = $socks | .EgressRegion = $region' \
         "$TMPDIR/$CONFIG_NAME" > "$TARGET_DIR/$CONFIG_NAME"; then
    echo "Failed to write config for $cc" >&2
    exit 1
  fi
  chown root:root "$TARGET_DIR/$CONFIG_NAME"
  chmod 644 "$TARGET_DIR/$CONFIG_NAME"

  echo "Prepared $TARGET_DIR (SOCKS:$socks_port REGION:$cc)"
done

# Create systemd template unit (overwrite existing)
UNIT_PATH="/etc/systemd/system/psiphon@.service"
cat > "$UNIT_PATH" <<'UNIT'
[Unit]
Description=Psiphon Tunnel Core instance %i
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5
# Running as root by default; change User= if you prefer an unprivileged user
User=root
WorkingDirectory=/etc/psiphon/%i
ExecStart=/etc/psiphon/%i/psiphon-tunnel-core-x86_64 -config /etc/psiphon/%i/psiphon.config
LimitNOFILE=65536
# Basic hardening
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 "$UNIT_PATH"

# Create systemd drop-in override to allow writes to the per-instance config dirs
DROPIN_DIR="/etc/systemd/system/psiphon@.service.d"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/override.conf" <<'OVR'
[Service]
# Allow writing to the per-instance config directory under /etc/psiphon
ReadWritePaths=/etc/psiphon/%i
OVR
chmod 644 "$DROPIN_DIR/override.conf"

# Reload systemd and enable+start instances
systemctl daemon-reload
for cc in "${COUNTRIES[@]}"; do
  svc="psiphon@${cc}.service"
  echo "Enabling+starting $svc"
  systemctl enable "$svc" >/dev/null 2>&1 || true
  # start or restart to pick up new config
  if systemctl is-active --quiet "$svc"; then
    systemctl restart "$svc" || echo "Warning: restart failed for $svc" >&2
  else
    systemctl start "$svc" || echo "Warning: start failed for $svc" >&2
  fi
done

 echo "Done. Services created for: ${COUNTRIES[*]}"
 echo "Verify a service: systemctl status psiphon@AT.service"
 echo "Check config values: jq '.LocalSocksProxyPort, .EgressRegion' /etc/psiphon/AT/psiphon.config"

# End of script
