#!/usr/bin/env bash
set -euo pipefail

BASE=/etc/psiphon
BIN_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
CFG_URL="https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/psiphon.config"
BIN=psiphon-tunnel-core-x86_64
COUNTRIES=(AT AU BE CA CH CZ DE DK EE ES FI FR GB IE IN LT IT JP NL NO PL RO RS SE SG RS US)
SOCKS_BASE=7001

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi
command -v curl >/dev/null || { echo "curl required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

# stop & disable existing instances (ignore errors)
for c in "${COUNTRIES[@]}"; do
  systemctl stop "psiphon@${c}.service" >/dev/null 2>&1 || true
  systemctl disable "psiphon@${c}.service" >/dev/null 2>&1 || true
done

# wipe previous installation
rm -rf "${BASE:?}"/*
mkdir -m 755 -p "$BASE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BIN_URL" -o "$TMP/$BIN"
chmod +x "$TMP/$BIN"
curl -fsSL "$CFG_URL" -o "$TMP/psiphon.config"

# prepare per-country dirs and configs (remove LocalHttpProxyPort, set socks & region)
for i in "${!COUNTRIES[@]}"; do
  c=${COUNTRIES[$i]}
  d="$BASE/$c"
  mkdir -p "$d"
  cp -f "$TMP/$BIN" "$d/$BIN"
  chmod 755 "$d/$BIN"
  socks=$((SOCKS_BASE + i))
  # use python3 to edit json: delete LocalHttpProxyPort if present, set LocalSocksProxyPort and EgressRegion
  python3 - <<PY > "$d/psiphon.config"
import json,sys
j=json.load(open("$TMP/psiphon.config"))
j.pop("LocalHttpProxyPort",None)
j["LocalSocksProxyPort"]=$socks
j["EgressRegion"]="${c}"
json.dump(j,open("$d/psiphon.config","w"),indent=2)
PY
  chmod 644 "$d/psiphon.config"
done

# systemd unit (template)
cat > /etc/systemd/system/psiphon@.service <<'UNIT'
[Unit]
Description=Psiphon Tunnel Core %i
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/etc/psiphon/%i
ExecStart=/etc/psiphon/%i/psiphon-tunnel-core-x86_64 -config /etc/psiphon/%i/psiphon.config
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

# allow write to /etc/psiphon/%i (fix read-only /etc from ProtectSystem)
mkdir -p /etc/systemd/system/psiphon@.service.d
cat > /etc/systemd/system/psiphon@.service.d/override.conf <<'OVR'
[Service]
ReadWritePaths=/etc/psiphon/%i
OVR

systemctl daemon-reload

# enable & start all instances
for c in "${COUNTRIES[@]}"; do
  systemctl enable --now "psiphon@${c}.service" >/dev/null 2>&1 || echo "start failed: ${c}"
done

echo "Done. Check: systemctl status psiphon@AT.service"
