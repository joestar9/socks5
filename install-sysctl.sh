#!/bin/bash
set -e

# --- Configuration Variables ---
SSH_PORT=8264
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDdcATaB3hKAJsbRByDEEvDEOeRWRUgPp8rU5HNtDmWA Generated"

# Define custom file paths (We will overwrite these files every time)
FILE_SYSCTL="/etc/sysctl.d/99-custom-tuning.conf"
FILE_LIMITS="/etc/security/limits.d/99-custom-tuning.conf"
FILE_SYSTEMD="/etc/systemd/system.conf.d/99-custom-tuning.conf"
FILE_MODULES="/etc/modules-load.d/custom-modules.conf"

echo ">>> Starting Clean & Idempotent Server Setup..."

# --- 1. SSH Setup (Smart Update) ---
echo "[+] Configuring SSH..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Only add key if not present
grep -qF "$SSH_KEY" ~/.ssh/authorized_keys || echo "$SSH_KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Reset Port and Settings in sshd_config to ensure no duplicates
sed -i 's/^Port .*/#&/' /etc/ssh/sshd_config
sed -i "/^Port $SSH_PORT/d" /etc/ssh/sshd_config # Remove specific port line if exists to avoid duplicate
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config    # Add it fresh

# Force security settings
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# --- 2. UFW Firewall (Reset & Re-apply) ---
echo "[+] Configuring UFW..."
command -v ufw >/dev/null || apt-get install -y -qq ufw
# Reset allows us to clear old rules before adding new ones
echo "y" | ufw reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw limit $SSH_PORT/tcp comment 'SSH Custom'
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable >/dev/null

# --- 3. ZRAM Setup (Overwrite Config) ---
echo "[+] Configuring ZRAM..."
apt-get install -y -qq zram-tools
# We rely on default config structure, strictly replacing values
sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap
sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
systemctl restart zramswap

# --- 4. Kernel Modules (Overwrite File) ---
echo "[+] Setting Persistent Kernel Modules..."
# Truncate and write (Overwrite)
cat > "$FILE_MODULES" <<EOF
tcp_bbr
nf_conntrack
EOF
modprobe tcp_bbr nf_conntrack

# --- 5. Sysctl Tuning (Overwrite File) ---
echo "[+] Applying Sysctl Rules..."
cat > "$FILE_SYSCTL" <<EOF
# Custom Network Tuning - Overwritten by setup script
net.ipv4.tcp_fack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.neigh.default.unres_qlen = 10000
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.lo.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.core.netdev_max_backlog = 100000
net.core.netdev_budget = 50000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 67108864
net.core.wmem_default = 67108864
net.core.optmem_max = 65536
net.core.somaxconn = 1000000
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 819200
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_frto = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.neigh.default.gc_thresh3 = 8192
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh1 = 2048
net.ipv6.neigh.default.gc_thresh3 = 8192
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh1 = 2048
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 5
vm.swappiness = 60
vm.vfs_cache_pressure = 100
vm.overcommit_memory = 1
kernel.pid_max = 64000
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_low_latency = 1
net.ipv6.icmp.echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_anycast = 1
net.ipv6.icmp.echo_ignore_multicast = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
sysctl --system >/dev/null

# --- 6. System Limits (Overwrite File) ---
echo "[+] Configuring Limits..."
# Using limits.d is safer and supports overwrite
cat > "$FILE_LIMITS" <<EOF
# Custom Limits - Overwritten by setup script
root soft nofile 1000000
root hard nofile 1000000
root soft nproc unlimited
root hard nproc unlimited
root soft core unlimited
root hard core unlimited
root hard memlock unlimited
root soft memlock unlimited
* soft nofile 1000000
* hard nofile 1000000
* soft nproc unlimited
* hard nproc unlimited
* soft core unlimited
* hard core unlimited
* hard memlock unlimited
* soft memlock unlimited
EOF

# --- 7. Systemd Global Config (Overwrite File) ---
echo "[+] Configuring Systemd..."
# Ensure directory exists
mkdir -p /etc/systemd/system.conf.d
# Create a drop-in file instead of editing system.conf directly
cat > "$FILE_SYSTEMD" <<EOF
# Custom Systemd Config - Overwritten by setup script
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=infinity
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF
systemctl daemon-reexec

# --- Finalization ---
systemctl restart sshd
echo ">>> Setup Complete. Settings are persistent and clean."
echo ">>> Please REBOOT to ensure all kernel settings are fully active."
