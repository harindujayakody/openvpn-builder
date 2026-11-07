# OpenVPN Builder

> Bulk OpenVPN Client Creator & Manager — One-Click Installer

![Platform](https://img.shields.io/badge/platform-Ubuntu%20%2F%20Debian-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Powered by](https://img.shields.io/badge/powered%20by-OpenVPN%20%2B%20EasyRSA-orange)
![DNS](https://img.shields.io/badge/DNS%20leak-protected-red)

---

## Overview

**OpenVPN Builder** sets up a full OpenVPN server with PKI on any Ubuntu/Debian VPS and lets you create, download, and revoke client `.ovpn` configs in bulk — all from a simple interactive menu.

After creation, the ZIP is saved on the server and downloaded over SSH with `scp`. Client ZIPs contain private keys, so they are **never** served over plain HTTP or shared as a public link.

Built with DNS leak prevention hardened for **Facebook / Meta traffic**.

---

## Features

- One-command install — full server + PKI in one shot
- Create single or **bulk clients (up to 200 at once)**
- **Auto ZIP** after every creation, delivered over SSH (`scp`)
- Optional localhost-only download server (127.0.0.1, reachable only via SSH tunnel) — no public HTTP server
- Re-download any previous client ZIP at any time
- Revoke clients (updates CRL, restarts server instantly)
- **DNS leak prevention** — `block-outside-dns` + Cloudflare 1.1.1.1
- **IPv6 leak prevention** — Facebook resolves to IPv6, this blocks that
- All Facebook/Meta IP ranges routed through tunnel
- AES-256-GCM + SHA256 + TLS 1.2 minimum, EC P-256 certificates, tls-crypt, CRL enforced from install

---

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 or Debian 10+
- Root or sudo access
- Public IPv4 address
- Port **1194/UDP** open

---

## Installation

```bash
bash <(curl -s https://raw.githubusercontent.com/harindujayakody/openvpn-builder/main/install-openvpn.sh)
```

After install, run anytime:

```bash
sudo openvpnbuilder
```

---

## Menu

```
╔══════════════════════════════════════════════════════════════╗
║                    OPENVPN BUILDER                          ║
║            Bulk Client Creator & Manager                    ║
╚══════════════════════════════════════════════════════════════╝

1) Create Single Client        (secure copy)
2) Create Bulk Clients         (auto ZIP + secure copy)
3) List All Clients
4) Re-Download a Client ZIP
5) Revoke / Delete Client
6) Server Status
7) Exit
```

---

## Bulk Create + Secure Download

Select **option 2**, enter count and prefix — done.

```
How many clients (1-200): 50
Name prefix (blank = 'client'): fb

→ fb_001   ✓
→ fb_002   ✓
...
→ fb_050   ✓

[OK]   All 50 clients packed → bulk_fb_20250311_142300.zip

  📦  CLIENT ZIP READY
  File    : /etc/openvpnbuilder/zips/bulk_fb_20250311_142300.zip

  Download over SSH (recommended):
  scp root@YOUR_SERVER_IP:/etc/openvpnbuilder/zips/bulk_fb_20250311_142300.zip .
```

The ZIP contains client private keys, so it is never served over plain HTTP.
If you cannot use `scp`, the menu can start a localhost-only server
(127.0.0.1) that you reach through an SSH tunnel (`ssh -L 8900:localhost:8900`).

---

## DNS Leak Prevention

Every client config includes:

```
block-outside-dns             # Windows: blocks all non-tunnel DNS
dhcp-option DNS 1.1.1.1       # Cloudflare primary (Facebook-friendly)
dhcp-option DNS 1.0.0.1       # Cloudflare secondary
redirect-gateway def1         # Forces ALL traffic through tunnel
tun-ipv6                      # IPv6 inside tunnel
pull-filter ignore "route-ipv6"      # Prevents IPv6 split routing
pull-filter ignore "ifconfig-ipv6"   # Prevents IPv6 outside tunnel
```

Server-side pushes all Facebook/Meta IP ranges (157.240.x.x, 31.13.x.x, 69.171.x.x, etc.) explicitly through the tunnel. iptables rules also block DNS queries from leaking outside port 53.

---

## File Locations

| Path | Description |
|------|-------------|
| `/etc/openvpnbuilder/clients/` | Individual `.ovpn` files |
| `/etc/openvpnbuilder/zips/` | ZIP archives (single + bulk) |
| `/etc/openvpnbuilder/clients.db` | Client database |
| `/etc/openvpnbuilder/easy-rsa/pki/` | PKI — CA, certs, keys |
| `/etc/openvpn/server/server.conf` | OpenVPN server config |
| `/var/log/openvpn/` | Server logs |

---

## Compatible Clients

| Platform | App |
|----------|-----|
| Windows | OpenVPN GUI / OpenVPN Connect |
| macOS | Tunnelblick / OpenVPN Connect |
| Linux | `openvpn --config client.ovpn` |
| Android | OpenVPN for Android |
| iOS | OpenVPN Connect |

---

## Uninstall

```bash
sudo systemctl stop openvpn-server@server
sudo apt-get remove --purge -y openvpn easy-rsa
sudo rm -rf /opt/openvpnbuilder /etc/openvpnbuilder
sudo rm -f /usr/local/bin/openvpnbuilder
```

---

## Author

**Harindu Jayakody**  
GitHub: [harindujayakody](https://github.com/harindujayakody)

---

## License

MIT License. Free to use, modify, and distribute.
