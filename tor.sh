#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

COUNTRIES=(tr de us fr uk at be ro ca sg jp ie fi es pl)
SOCKS_BASE=6001
BASE_ETC=/etc/tor-proxy
BASE_VAR=/var/lib/tor
LOG_DIR=/var/log/tor
TORBIN=/usr/bin/tor

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

# install tor if missing
if [ ! -x "$TORBIN" ]; then
  echo "[info] Installing tor..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq tor || { echo "[error] apt install tor failed"; exit 1; }
fi

# ensure debian-tor user exists
id -u debian-tor >/dev/null 2>&1 || useradd --system --home-dir /var/lib/tor --shell /usr/sbin/nologin debian-tor || true

# create base dirs
mkdir -p "$BASE_ETC" "$BASE_VAR" "$LOG_DIR"
chown root:root "$BASE_ETC"
chown -R debian-tor:debian-tor "$BASE_VAR" "$LOG_DIR" 2>/dev/null || true
chmod 755 "$BASE_ETC" || true

# overwrite torrc for each country with speed-first config
for i in "${!COUNTRIES[@]}"; do
  code="${COUNTRIES[$i]}"
  socks=$((SOCKS_BASE + i))
  etcdir="$BASE_ETC/$code"
  datadir="$BASE_VAR/$code"
  logfile="$LOG_DIR/$code.log"

  mkdir -p "$etcdir" "$datadir"
  chown -R debian-tor:debian-tor "$datadir"
  chmod 700 "$datadir" || true
  touch "$logfile"; chown debian-tor:debian-tor "$logfile" 2>/dev/null || true
  chmod 640 "$logfile" || true

  cat > "$etcdir/torrc" <<EOF
#torrc for $code
SocksPort 127.0.0.1:$socks
DataDirectory $datadir
ExitNodes {$code}
StrictNodes 1
RunAsDaemon 0
#Log notice file $logfile
NumEntryGuards 1
UseEntryGuards 1
NewCircuitPeriod 86400
MaxCircuitDirtiness 86400
CircuitBuildTimeout 60
AvoidDiskWrites 1
MaxClientCircuitsPending 1024
EOF

  chmod 644 "$etcdir/torrc"
  echo "[info] wrote $etcdir/torrc (socks:127.0.0.1:$socks)"
done

# ensure systemd template (minimal) exists
cat > /etc/systemd/system/tor-proxy@.service <<'UNIT'
[Unit]
Description=Tor proxy instance %i
After=network.target

[Service]
Type=simple
User=debian-tor
Group=debian-tor
ExecStart=/usr/bin/tor -f /etc/tor-proxy/%i/torrc
Restart=on-failure
RestartSec=5
LimitNOFILE=32768
WorkingDirectory=/var/lib/tor/%i

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 /etc/systemd/system/tor-proxy@.service
systemctl daemon-reload

# restart all instances
for c in "${COUNTRIES[@]}"; do
  systemctl restart "tor-proxy@${c}.service" >/dev/null 2>&1 || echo "[warn] restart failed: $c"
done

echo "[done] Configs written and instances restarted."
echo "Check one instance: systemctl status tor-proxy@tr.service"
echo "Tail logs: journalctl -u tor-proxy@tr.service -f"
