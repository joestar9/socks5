#!/usr/bin/env bash
set -euo pipefail

# URL of the remote sysctl.conf
URL="https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/sysctl.conf"
TARGET_ETC="/etc/sysctl.conf"
TARGET_D="/etc/sysctl.d/99-k4yt3x.conf"
TMP="$(mktemp --tmpdir sysctl.XXXXXX)"

cleanup() {
  rm -f "$TMP"
}
trap cleanup EXIT

# Must be root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Use sudo."
  exit 1
fi

# Ensure curl or wget is available; install curl if neither exist
if command -v curl >/dev/null 2>&1; then
  FETCH_CMD="curl -fsSL -o \"$TMP\" \"$URL\""
elif command -v wget >/dev/null 2>&1; then
  FETCH_CMD="wget -qO \"$TMP\" \"$URL\""
else
  apt-get update -y
  apt-get install -y curl
  command -v curl >/dev/null 2>&1 || { echo "Failed to install curl."; exit 1; }
  FETCH_CMD="curl -fsSL -o \"$TMP\" \"$URL\""
fi

# Download
eval $FETCH_CMD

if [ ! -s "$TMP" ]; then
  echo "Downloaded file is empty or download failed."
  exit 1
fi

# Quick sanity check for sysctl format
if ! grep -qE '^[[:space:]]*[a-z0-9._]+\s*=' "$TMP"; then
  echo "Downloaded file doesn't look like a sysctl.conf."
  exit 1
fi

# NOTE: Do NOT back up /etc/sysctl.conf per user request.
# Backup /etc/sysctl.d/99-k4yt3x.conf if it exists, keep earlier behavior for the .d file
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [ -f "$TARGET_D" ]; then
  cp -a "$TARGET_D" "${TARGET_D}.bak-$TIMESTAMP"
  echo "Backup created: ${TARGET_D}.bak-$TIMESTAMP"
fi

# Install files
install -m 0644 "$TMP" "$TARGET_D"
install -m 0644 "$TMP" "$TARGET_ETC"
chown root:root "$TARGET_D" "$TARGET_ETC"

# Apply settings
if command -v sysctl >/dev/null 2>&1; then
  sysctl --system
  sysctl -p "$TARGET_ETC" || true
else
  echo "sysctl command not found; ensure procps is installed."
  exit 1
fi

echo "Done. Installed to:"
echo " - $TARGET_D"
echo " - $TARGET_ETC"
