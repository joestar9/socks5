To install the Psiphon service script, execute the following command:

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/Pinstaller.sh | bash
```

check Psiphon ip

```bash
curl --socks5-hostname 127.0.0.1:7001 https://ifconfig.me
```

To install the Tor service, execute the following command:

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/tor.sh | bash
```

check Tor ip

```bash
curl --socks5-hostname 127.0.0.1:6001 https://ifconfig.me
```

To install the sysctl service, execute the following command:

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/install-sysctl.sh | bash
```

To install the VPS optimizer, execute the following command:

```bash
curl -s https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/optimizer.sh | bash
```


To install the rw-backup, execute the following command:

```bash
curl -o ~/backup-restore.sh https://raw.githubusercontent.com/joestar9/socks5/refs/heads/main/rw-backup.sh && chmod +x ~/backup-restore.sh && ~/backup-restore.sh
```

