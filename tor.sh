#!/usr/bin/env bash
# tor-clean-install.sh
# Destructive by design: remove previous tor-proxy instances/configs/logs for listed countries,
# then install tor (if needed) and create per-country tor instances (SOCKS5).
set -euo pipefail
IFS=$'\n\t'

# ----- config -----
COUNTRIES=(al at au be by ca ch es fi fr hk jp md nl pl ro ru sg se tr ua gb us)
SOCKS_BASE=6001
BASE_ETC=/etc/tor-proxy
BASE_VAR=/var/lib/tor
LOG_DIR=/var/log/tor
TORBIN=/usr/bin/tor

# ----- sanity -----
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }

echo "[*] Starting: will REMOVE previous tor-proxy configs/services/logs for: ${COUNTRIES[*]}"
echo "[*] If you didn't mean this, Ctrl-C now."

# small pause to allow user cancel (can remove if you want zero-interaction)
sleep 2

# ----- stop & disable matching units (safe extraction) -----
echo "[*] Stopping and disabling existing tor-proxy@*.service units..."
systemctl list-units --type=service --all --no-legend --no-pager \
  | grep -oE 'tor-proxy@[A-Za-z0-9._-]+\.service' \
  | sort -u \
  | xargs -r -n1 systemctl stop || true

systemctl list-unit-files --no-legend --no-pager \
  | grep -oE 'tor-proxy@[A-Za-z0-9._-]+\.service' \
  | sort -u \
  | xargs -r -n1 systemctl disable || true

# ----- remove unit files we manage -----
echo "[*] Removing systemd unit template and drop-ins..."
rm -f /etc/systemd/system/tor-proxy@.service
rm -rf /etc/systemd/system/tor-proxy@.service.d
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true

# ----- remove per-country configs, datadirs, logs -----
echo "[*] Removing per-country config, data and logs..."
for c in "${COUNTRIES[@]}"; do
  echo "    -> cleaning $c"
  rm -rf "${BASE_ETC:?}/$c"
  rm -rf "$BASE_VAR/$c"
  rm -f "$LOG_DIR/$c.log"
done

# also remove base etc dir if empty
rmdir --ignore-fail-on-non-empty "$BASE_ETC" 2>/dev/null || true

# ----- minimal install of tor if missing -----
if [ ! -x "$TORBIN" ]; then
  echo "[*] tor not found: installing via apt..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq tor || { echo "[ERROR] apt install tor failed"; exit 1; }
fi

# ensure system user
if ! id -u debian-tor >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/tor --shell /usr/sbin/nologin debian-tor || true
fi

# ----- prepare base dirs -----
mkdir -p "$BASE_ETC" "$BASE_VAR" "$LOG_DIR"
chown root:root "$BASE_ETC"
chown -R debian-tor:debian-tor "$BASE_VAR" "$LOG_DIR" 2>/dev/null || true
chmod 755 "$BASE_ETC" || true

# ----- write per-country torrc (speed-first, ExitNodes lowercase) -----
echo "[*] Creating per-country configs..."
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

# speed/persistence tuning (security deprioritized)
NumEntryGuards 1
UseEntryGuards 1
NewCircuitPeriod 86400
MaxCircuitDirtiness 86400
CircuitBuildTimeout 60
AvoidDiskWrites 1
MaxClientCircuitsPending 1024
EOF

done

# ----- systemd template -----
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

# ----- enable & start instances -----
echo "[*] Enabling and starting instances..."
for code in "${COUNTRIES[@]}"; do
  systemctl enable --now "tor-proxy@${code}.service" >/dev/null 2>&1 || echo "[warn] start failed: $code"
done

# ----- summary -----
echo
echo "===== SUMMARY ====="
for i in "${!COUNTRIES[@]}"; do
  code="${COUNTRIES[$i]}"
  port=$((SOCKS_BASE + i))
  svc="tor-proxy@${code}.service"
  printf "%-4s  socks=127.0.0.1:%-5d  " "$code" "$port"
  if systemctl is-active --quiet "$svc"; then
    printf "\e[1;32mRUNNING\e[0m\n"
  else
    printf "\e[1;31mFAILED\e[0m\n"
  fi
done

echo
echo "[*] Done. Check an instance: systemctl status tor-proxy@tr.service"
echo "[*] Test SOCKS: curl --socks5-hostname 127.0.0.1:7001 https://ifconfig.me"
