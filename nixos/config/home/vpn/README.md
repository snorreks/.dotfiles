# Proton VPN WireGuard Configuration

VPN configs live in `~/.vpn/configs/` (NOT tracked by Nix or Git — they contain private keys).

## Setup

1. Download WireGuard configs from https://account.protonvpn.com/downloads#wireguard-configuration
2. Add a comment line at the top of each `.conf` with the server label (used by Waybar tooltip):

   ```
   # NL-FREE#217
   [Interface]
   PrivateKey = ...your real key...
   Address = 10.2.0.2/32
   DNS = 10.2.0.1
   ```

3. Place files in `~/.vpn/configs/`:

   ```
   ~/.vpn/configs/
   ├── nl-free-217.conf
   ├── nl-free-156.conf
   └── us-free.conf
   ```

## Example template (replace with real keys!)

```
# NL-FREE#217
[Interface]
PrivateKey = YOUR_ACTUAL_PRIVATE_KEY
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = QGD/PKdxVXt9h0+gN7x8zB70sexJfv+0hhiJQou1BVc=
Endpoint = 185.165.240.23:51820
AllowedIPs = 0.0.0.0/0
```
