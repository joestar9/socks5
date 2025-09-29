#!/usr/bin/env bash
# remove-tor-clean-fixed.sh
# Robust removal of tor + tor-proxy instances and related files.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }

echo "[info] Stopping main tor.service if present..."
systemctl stop tor.service >/dev/null 2>&1 || true
systemctl disable tor.service >/dev/null 2>&1 || true

echo "[info] Stopping and disabling tor-proxy@*.service (safe extraction)..."
# stop actual units matching pattern (avoid decorative chars)
systemctl list-units --type=service --all --no-legend --no-pager \
  | grep -oE 'tor-proxy@[A-Za-z0-9._-]+\.service' \
  | sort -u \
  | xargs -r -n1 sudo systemctl stop || true

systemctl list-unit-files --no-legend --no-pager \
  | grep -oE 'tor-proxy@[A-Za-z0-9._-]+\.service' \
  | sort -u \
  | xargs -r -n1 sudo systemctl disable || true

echo "[info] Removing systemd unit files we created..."
rm -f /etc/systemd/system/tor-proxy@.service
rm -rf /etc/systemd/system/tor-proxy@.service.d
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true

echo "[info] Purging tor packages (best-effort, apt)..."
apt-get update -qq || true
apt-get purge -y tor torsocks torbrowser-launcher 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true

echo "[info] Removing config/data/log directories created by installer..."
rm -rf /etc/tor-proxy
rm -rf /var/lib/tor
rm -rf /var/log/tor

# optional: don't blindly delete distro /etc/tor unless user wants full wipe
if [ -d /etc/tor ]; then
  echo "[warn] Removing /etc/tor (system tor config). This is irreversible."
  rm -rf /etc/tor
fi

# Move any journal files that have 'tor' in name to backup (safer than rm)
journal_dir=/var/log/journal
if [ -d "$journal_dir" ]; then
  mkdir -p /root/backup-journals
  find "$journal_dir" -type f \( -iname '*tor*' -o -iname '*debian-tor*' \) -print0 \
    | xargs -0 -r -I{} mv -f {} /root/backup-journals/ 2>/dev/null || true
fi

# remove system user (best-effort)
if id -u debian-tor >/dev/null 2>&1; then
  userdel -r debian-tor >/dev/null 2>&1 || true
fi

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true

echo "[done] Tor and related files removed. If any journal files were moved, see /root/backup-journals/"

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

COUNTRIES=(al at au be by ca ch es fi fr hk jp md nl pl ro ru sg se tr ua gb us)
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
Log notice file $logfile
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
