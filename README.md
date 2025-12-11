# 🚀 VPS Essentials Toolkit

A small, curated set of scripts to quickly configure and optimize a Linux VPS for proxying, networking and basic maintenance. Each script is standalone and can be run directly from the server using curl | bash. Use with caution and review scripts before running.

---

## Quick index

1. Psiphon Tunnel — Socks5 on port 7001
2. Tor Service — Socks5 on port 6001
3. Network Optimization — BBR & sysctl tuning
4. VPS Optimizer — General cleanup & tuning
5. Backup & Restore (RW-Backup) — Panel config backup/restore
6. SSL Certificate Manager — acme.sh / Let's Encrypt automation

---

## Usage

Run any script directly on your VPS (recommended as root or with sudo):

```bash
# Psiphon
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/Pinstaller.sh)

# Tor
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/tor.sh)

# Network tuning (BBR & sysctl)
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/install-sysctl.sh)

# General optimizer
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/optimizer.sh)

# Backup & Restore
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/rw-backup.sh)

# SSL manager (if present)
bash <(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/acme.sh)
```

> Tip: Always inspect scripts before running. For example: curl -sS https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/Pinstaller.sh | sed -n '1,200p'

---

## Verify proxy IP (examples)

Psiphon (Socks5 @ 127.0.0.1:7001):

```bash
curl --socks5-hostname 127.0.0.1:7001 https://ifconfig.me
```

Tor (Socks5 @ 127.0.0.1:6001):

```bash
curl --socks5-hostname 127.0.0.1:6001 https://ifconfig.me
```

---

## Ports & Services

- Psiphon: 7001 (Socks5)
- Tor: 6001 (Socks5)
- Adjust firewall rules (ufw/iptables) as needed to allow local usage and to restrict external access.

---

## Security & best practices

- Review every script before running. Do not run untrusted scripts as root.
- Use non-root users where possible and limit exposure of proxy ports.
- Keep your system and installed packages up to date.

---

## Troubleshooting

- If a script fails, check logs in /var/log or the journal (journalctl -xe).
- Ensure the server has internet access and DNS working: ping 1.1.1.1 && ping google.com
- For service-specific issues (tor, psiphon), check their respective systemd unit status, e.g.:

```bash
systemctl status tor
journalctl -u tor --no-pager -n 200
```

---

## Contributing

Feel free to open issues or PRs with fixes, improvements or updated scripts. When contributing:
- Add a clear description of the change
- Test scripts on a disposable VPS before submitting

---

## License

This repository is provided as-is. See LICENSE for details (or add one if missing).

---

If you'd like, I can also:
- Add a short security checklist for running these scripts
- Add usage examples for systemd service management
- Create a quick start script that runs basic sanity checks before executing installers
