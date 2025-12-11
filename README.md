# 🚀 VPS Essentials Toolkit

A collection of useful scripts for VPS configuration, proxy setup, and system optimization.

---

### 🌀 1. Psiphon Tunnel
Installs Psiphon service running on Socks5 port `7001`.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/Pinstaller.sh)
Verify IP:

bash
curl --socks5-hostname 127.0.0.1:7001 https://ifconfig.me
🧅 2. Tor Service
Installs Tor service running on Socks5 port 6001.

bash
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/tor.sh)
Verify IP:

bash
curl --socks5-hostname 127.0.0.1:6001 https://ifconfig.me
🛠️ 3. Network Optimization (BBR & Sysctl)
Optimizes kernel parameters for better network throughput and lower latency.

bash
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/install-sysctl.sh)
⚡ 4. VPS Optimizer
General system cleanup and performance tuning.

bash
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/optimizer.sh)
💾 5. Backup & Restore (RW-Backup)
Easily backup or restore your panel configurations.

bash
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/rw-backup.sh)
🔐 6. SSL Certificate Manager
Automated SSL issuance using acme.sh & Let's Encrypt (Supports Wildcard & Multi-domain).

bash
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/head
