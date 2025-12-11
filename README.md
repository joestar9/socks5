# Tools – Quick Installation

## Install Psiphon Service

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/Pinstaller.sh | bash
```

Check your Psiphon IP:
```bash
curl --socks5-hostname 127.0.0.1:7001 https://ifconfig.me
```

---

## Install Tor Service

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/tor.sh | bash
```

Check your Tor IP:
```bash
curl --socks5-hostname 127.0.0.1:6001 https://ifconfig.me
```

---

## Install Sysctl Optimization

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/install-sysctl.sh | bash
```

---

## Install VPS Optimizer

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/optimizer.sh | bash
```

---

## Install and Run RW-Backup Script

```bash
curl -o ~/backup-restore.sh https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/rw-backup.sh && chmod +x ~/backup-restore.sh && ~/backup-restore.sh
```


---

## Install Cert-Manager

```bash
<(curl -Ls https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/cert-manager.sh)
```
