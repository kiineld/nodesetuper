# remnanode-autoinstall

One script that takes a bare Debian/Ubuntu VPS to a Remnawave node that is already
registered in your panel and already reporting to your beszel hub.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/kiineld/nodesetuper/main/install-node.sh)
```

## What you type

Edit `PANEL_URL` and `BESZEL_HUB_URL` at the top of the script once, push it, and
every run after that asks only for:

| Prompt | Used for |
|---|---|
| Node domain | selfsteal site, the node's `address` in the panel, ACME cert |
| Node name | panel node name (3–30 chars) |
| Remnawave API token | panel API auth |
| Beszel hub email + password | fetching the hub key and universal token |
| Disable IPv6? | y/N switch |

Every prompt has an environment-variable equivalent, so it also runs unattended:

```bash
NODE_DOMAIN=de1.example.com NODE_NAME=DE-1 REMNA_TOKEN=xxx \
BESZEL_EMAIL=me@example.com BESZEL_PASSWORD=yyy DISABLE_IPV6=yes \
bash install-node.sh
```

The beszel account must be a **regular user**, not a superuser — the hub refuses
to issue universal tokens to superusers.

## What it does

1. **Preflight** — root/OS check, installs `curl jq ufw dnsutils iproute2`, detects public IPv4 and country code, warns if the domain's A record is missing or Cloudflare-proxied.
2. **Validates the panel token** before touching anything, and detects a node that is already registered under the same name or address.
3. **Resolves the config profile** — auto if there is exactly one, numbered picker otherwise, or set `CONFIG_PROFILE_UUID`.
4. **Beszel login** → `GET /api/beszel/getkey` for the hub public key, `GET /api/beszel/universal-token` for the token (reuses an active one, otherwise mints a 1-hour ephemeral one; `BESZEL_PERMANENT_TOKEN=yes` makes it permanent).
5. **Docker** via `get.docker.com`, skipped if present.
6. **Kernel tuning** — see below.
7. **ufw** — rules added *before* `enable`, port 22 kept open until the new SSH port is verified.
8. **selfsteal** — `install --force --domain <domain> --port 9443`.
9. **Certificates** — locates the cert Caddy just issued, inside its Docker volume.
10. **Remnanode** — `GET /api/keygen` → `SECRET_KEY` → `docker-compose.yml` → `up -d`, verified running.
11. **Cert renewal watcher** — daily systemd timer, restarts the node when the cert changes.
12. **Registers the node** — `POST /api/nodes`.
13. **WARP** — warp-native, driven non-interactively.
14. **Beszel agent** — auto-registers itself with the hub.
15. **SSH → 2224** — verified, then port 22 is closed.

## Firewall

| Port | Source | Purpose |
|---|---|---|
| 2224/tcp | any | SSH |
| 80/tcp | any | ACME + selfsteal HTTP |
| 443/tcp | any | Xray Reality |
| 443/udp | any | Xray QUIC |
| 45876/tcp | any | beszel agent |
| 2222/tcp | **panel IP only** | Remnawave panel → node |

The panel IP is resolved from `PANEL_URL`; override with `PANEL_IP=`. If it cannot
be resolved the script opens 2222 to everyone and says so loudly.

A re-run does **not** reset ufw, so hand-added rules survive.

## Kernel tuning

`/etc/sysctl.d/99-remnanode-tuning.conf`:

- **BBR + fq** — `fq` is the qdisc BBR is designed to pace against. If the kernel has no BBR the script warns and leaves congestion control alone rather than writing a setting that silently fails.
- **Large socket buffers** (16 MB max, 1 MB default, `udp_rmem_min`) — this is the one that most affects QUIC on 443/udp, which is handled in userspace and drops packets silently when the kernel buffer overflows.
- **`tcp_mtu_probing=1`** — matters specifically *because* the script disables ICMP echo: paths that black-hole "fragmentation needed" would otherwise stall, and probing recovers them.
- **`tcp_slow_start_after_idle=0`, `notsent_lowat`, `tcp_fastopen=3`** — latency on bursty VPN traffic.
- **Backlogs and port range** — `somaxconn`, `netdev_max_backlog`, `tcp_max_syn_backlog`, `ip_local_port_range 1024–65535`.
- **`ip_forward=1`** for WARP and routed outbounds.
- `nofile` raised to 1048576 via `limits.d`, a systemd drop-in, and the container's `ulimits`.

ICMP echo and the IPv6 switch live in their own `sysctl.d` files, so re-running
never stacks duplicate lines the way `>> /etc/sysctl.conf` does.

## TLS certificates

Selfsteal's Caddy obtains a Let's Encrypt cert. The script finds it by inspecting
the Caddy container for its `/data` volume, then globbing
`caddy/certificates/*/<domain>/<domain>.crt` — the CA directory name is globbed
rather than hardcoded because it differs between Let's Encrypt and the ZeroSSL
fallback. The two files are bind-mounted read-only into the node:

```yaml
volumes:
  - <caddy-volume>/caddy/certificates/<ca>/<domain>/<domain>.crt:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro
  - <caddy-volume>/caddy/certificates/<ca>/<domain>/<domain>.key:/var/lib/remnawave/configs/xray/ssl/key.pem:ro
```

Certmagic rewrites these files in place on renewal, so the inode survives and the
bind mount stays valid — but Xray still caches the old cert, so
`remnanode-cert-watch.timer` checks the fingerprint daily and restarts the
container when it changes.

If ACME has not finished within 120 s the script says so and starts the node
*without* the cert mounts, rather than letting Docker create directories where the
cert files should be. Re-run once the cert exists.

Reference the certs in your Xray config as:

```json
"certificates": [{
  "certificateFile": "/var/lib/remnawave/configs/xray/ssl/cert.pem",
  "keyFile": "/var/lib/remnawave/configs/xray/ssl/key.pem"
}]
```

## Safety

- The token, beszel login, and config profile are all validated **before** the first system change, so a typo fails at step 4 and not halfway through a rewritten firewall.
- ufw rules are added before `ufw enable`, never after.
- SSH: the port is set via `/etc/ssh/sshd_config.d/99-remnanode-port.conf`, not `sed` on `sshd_config` — on Ubuntu 22.04+ a cloud-init drop-in is read last and would override an edited main file. `ssh.socket` is disabled first because socket activation ignores `Port`. The config is validated with `sshd -t`, and port 22 is only closed after something is confirmed listening on 2224. Any failure rolls back and leaves 22 open.
- Re-running is safe: every step is idempotent and an already-registered node is skipped rather than duplicated.
- Full transcript at `/var/log/remnanode-autoinstall.log`.

## Not automated

- The DNS A record must be **DNS-only**, not Cloudflare-proxied, or the panel cannot reach port 2222.
- Your Reality inbound in the panel must list the node domain in `serverNames` and point `dest` at `127.0.0.1:9443`. The script prints both reminders at the end.

## Options

| Variable | Default | Effect |
|---|---|---|
| `PANEL_IP` | resolved from `PANEL_URL` | source IP allowed on port 2222 |
| `PANEL_EXTRA_HEADER` | – | extra header if the panel sits behind header auth, e.g. `"X-Api-Key: secret"` |
| `CONFIG_PROFILE_UUID` | – | skip the profile picker |
| `COUNTRY_CODE` | auto | node country code |
| `NODE_PORT` / `SSH_PORT` / `SELFSTEAL_PORT` / `BESZEL_PORT` | 2222 / 2224 / 9443 / 45876 | ports |
| `DISABLE_IPV6` | prompt | `yes` / `no` |
| `BESZEL_PERMANENT_TOKEN` | `no` | persist the universal token on the hub |
| `SKIP_WARP` | `no` | skip WARP |
| `SKIP_SSH_PORT` | `no` | leave SSH on port 22 |
