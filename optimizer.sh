#!/usr/bin/env bash
set -euo pipefail

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDdcATaB3hKAJsbRByDEEvDEOeRWRUgPp8rU5HNtDmWA'
SSH_PORT=8264
SSHD_CONF='/etc/ssh/sshd_config'

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi


# Ensure root .ssh exists and correct permissions
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Add public key if not already present
if ! grep -Fxq "$PUBKEY" /root/.ssh/authorized_keys; then
  echo "$PUBKEY" >> /root/.ssh/authorized_keys
  echo "Public key added to /root/.ssh/authorized_keys"
else
  echo "Public key already present"
fi

# Backup sshd_config
bak="${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$SSHD_CONF" "$bak"
echo "Backed up $SSHD_CONF -> $bak"

# Helper to set or append directive in sshd_config
set_sshd_option() {
  local key="$1" value="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$SSHD_CONF"; then
    sed -ri "s@^[#[:space:]]*${key}[[:space:]]+.*@${key} ${value}@" "$SSHD_CONF"
  else
    echo "${key} ${value}" >> "$SSHD_CONF"
  fi
}

# Configure SSH
set_sshd_option Port "$SSH_PORT"
set_sshd_option PasswordAuthentication no
set_sshd_option PubkeyAuthentication yes
set_sshd_option PermitRootLogin prohibit-password
set_sshd_option ChallengeResponseAuthentication no
set_sshd_option AuthorizedKeysFile .ssh/authorized_keys

# Ensure sshd listens on the new port immediately (restart)
systemctl restart ssh

# Configure UFW - apply rules the way you specified (non-interactive)
ufw default deny incoming
ufw default allow outgoing
ufw limit "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp

# Disable then enable as requested (force to avoid interactive prompt)
ufw --force disable
ufw --force enable

# Install zram-tools
apt install -y zram-tools

# Configure /etc/default/zramswap
cat > /etc/default/zramswap <<EOF
ALGO=lz4
PERCENT=25
PRIORITY=100
EOF

# Restart zramswap service
systemctl restart zramswap

echo "ZRAM enabled:"
zramctl
swapon --show

# --- system.conf ---
rm -f /etc/systemd/system.conf
cat << EOF > /etc/systemd/system.conf
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=infinity
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF

# --- limits.conf ---
rm -f /etc/security/limits.conf
cat << EOF > /etc/security/limits.conf
root     soft   nofile    1000000
root     hard   nofile    1000000
root     soft   nproc     unlimited
root     hard   nproc     unlimited
root     soft   core      unlimited
root     hard   core      unlimited
root     hard   memlock   unlimited
root     soft   memlock   unlimited
*     soft   nofile    1000000
*     hard   nofile    1000000
*     soft   nproc     unlimited
*     hard   nproc     unlimited
*     soft   core      unlimited
*     hard   core      unlimited
*     hard   memlock   unlimited
*     soft   memlock   unlimited
EOF

# --- sysctl.conf ---
rm -f /etc/sysctl.conf
cat << EOF > /etc/sysctl.conf
# IPv4 + IPv6 forwarding
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.lo.forwarding = 1

# Disable IPv6 disable flags
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0

# Router advertisement handling (IPv6)
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2

# IPv4 neigh tuning
net.ipv4.neigh.default.unres_qlen=10000
net.ipv4.neigh.default.gc_thresh3=8192
net.ipv4.neigh.default.gc_thresh2=4096
net.ipv4.neigh.default.gc_thresh1=2048

# IPv6 neigh tuning
net.ipv6.neigh.default.gc_thresh3=8192
net.ipv6.neigh.default.gc_thresh2=4096
net.ipv6.neigh.default.gc_thresh1=2048

# ICMP suppression (IPv4 + IPv6)
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv6.icmp.echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_multicast = 1
net.ipv6.icmp.echo_ignore_anycast = 1

# Redirects (IPv4 + IPv6)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Anti-spoof
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0

# TCP keepalive
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 2

# TCP stack settings
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_fin_timeout = 15

net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 819200
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_frto = 0
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_fack = 1
net.ipv4.tcp_early_retrans = 3

# Memory / buffers
net.core.netdev_max_backlog = 100000
net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 5000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.core.optmem_max = 65536
net.core.somaxconn = 1000000

# UDP
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Port range
net.ipv4.ip_local_port_range = 1024 65535

# Kernel params
vm.swappiness = 1
vm.overcommit_memory = 1
kernel.pid_max=64000

# conntrack
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144

# Enable fq + BBR
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_ecn = 1
net.ipv6.tcp_ecn = 1
EOF

# Apply changes
sysctl --system
systemctl daemon-reload
systemctl restart systemd-journald.service
systemctl restart networking.service 2>/dev/null || true

echo "Done."
