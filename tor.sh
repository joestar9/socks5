#!/usr/bin/env bash
# tor.sh  -- minimal, functional per-country tor instances (speed-first)
set -euo pipefail
IFS=$'\n\t'

# config
COUNTRIES=(al at au be by ca ch es fi fr hk jp md nl pl ro ru sg se tr ua gb us)
SOCKS_BASE=6001
BASE_ETC=/etc/tor-proxy
BASE_VAR=/var/lib/tor
LOG_DIR=/var/log/tor
TORBIN=/usr/bin/tor

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

# install tor if missing
if [ ! -x "$TORBIN" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq tor || { echo "apt install tor failed"; exit 1; }
fi

# ensure system user
if ! id -u debian-tor >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/tor --shell /usr/sbin/nologin debian-tor || true
fi

# prepare dirs
rm -rf "${BASE_ETC:?}"/* 2>/dev/null || true
mkdir -p "$BASE_ETC" "$BASE_VAR" "$LOG_DIR"
chown root:root "$BASE_ETC"
chown -R debian-tor:debian-tor "$BASE_VAR" "$LOG_DIR" 2>/dev/null || true
chmod 755 "$BASE_ETC" || true

# write per-country torrcs
for i in "${!COUNTRIES[@]}"; do
  code="${COUNTRIES[$i]}"
  socks=$((SOCKS_BASE + i))
  etcdir="$BASE_ETC/$code"
  datadir="$BASE_VAR/$code"
  logfile="$LOG_DIR/$code.log"

  mkdir -p "$etcdir" "$datadir"
  chown -R debian-tor:debian-tor "$datadir"
  chmod 700 "$datadir" || true
  : > "$logfile"
  chown debian-tor:debian-tor "$logfile" 2>/dev/null || true
  chmod 640 "$logfile" || true

  cat > "$etcdir/torrc" <<EOF
# torrc for $code (speed-first)
SocksPort 127.0.0.1:$socks
DataDirectory $datadir
ExitNodes {$code}
StrictNodes 1
RunAsDaemon 0
Log notice file $logfile

# speed tuning (persistence & throughput over security)
NumEntryGuards 1
UseEntryGuards 1
NewCircuitPeriod 86400
MaxCircuitDirtiness 86400
CircuitBuildTimeout 60
AvoidDiskWrites 1
MaxClientCircuitsPending 1024
EOF

done

# systemd template (minimal)
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

# enable & start all instances (sequential, minimal output)
for code in "${COUNTRIES[@]}"; do
  systemctl enable --now "tor-proxy@${code}.service" >/dev/null 2>&1 || echo "[warn] start failed: $code"
done

echo "done. SOCKS start at $SOCKS_BASE. check: systemctl status tor-proxy@tr.service"
