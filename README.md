# remnanode-autoinstall

One script that takes a bare Debian/Ubuntu VPS to a Remnawave node that is already
registered in your panel and already reporting to your beszel hub.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/kiineld/nodesetuper/main/install-node.sh)
```

## What you type

Edit `PANEL_URL`, `BESZEL_HUB_URL`, `REGRU_ZONE` and `REGRU_USER` at the top of the
script once, push it, and every run after that asks only for:

| Prompt | Used for |
|---|---|
| Subdomain label | e.g. `de1` — combined with `REGRU_ZONE` into the full hostname |
| Node name | panel node name (3–30 chars) |
| Remnawave API token | panel API auth |
| Beszel hub email + password | fetching the hub key and universal token |
| reg.ru API password | creating the A record |
| Disable IPv6? | y/N switch |

The server's public IPv4 is detected automatically and becomes the A record's
value — you never type an IP.

Answer `no` to the DNS prompt (or set `MANAGE_DNS=no`) to manage the record
yourself; the script then asks for the full hostname instead of a label.

## Arguments

Any prompt can be pre-answered as a `key=value` argument, in any order. Whatever
you leave out is still asked for interactively, so you can fill in as much or as
little as you like:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/kiineld/nodesetuper/main/install-node.sh) \
  rpanelurl=https://panelservice.rustafield.site sub=de1 name=DE-1
```

Keys are case- and separator-insensitive: `rpanelurl=`, `RPANEL_URL=`, `--panel-url=`
all set the same thing. Run `--help` for the full list. Environment variables work too.

Values passed as arguments are visible to other users via `ps` and land in your
shell history — for secrets, prefer letting the script prompt you.

## When something fails

Only two things are fatal: an invalid panel token, and the node container failing
to start. Everything else — DNS, selfsteal, beszel, WARP, the SSH port change —
reports the failure, records it, and carries on. The run ends with a list:

```
     Finished with 2 step(s) skipped or failed:
       ✗ Beszel hub — login failed: ...
       ✗ DNS — reg.ru refused this server's IP (1.2.3.4)
     The node itself is up; re-run to retry just these.
```

Re-running is safe and picks up where it left off.

The beszel account must be an **ordinary user**, not a superuser — the hub refuses
to issue universal tokens to superusers. See [Beszel login](#beszel-login) if it
fails.

## What it does

1. **Preflight** — root/OS check, installs `curl jq ufw dnsutils iproute2`, detects public IPv4 and country code, warns if the domain's A record is missing or Cloudflare-proxied.
2. **Validates the panel token** before touching anything, and detects a node that is already registered under the same name or address.
3. **Resolves the config profile** — auto if there is exactly one, numbered picker otherwise, or set `CONFIG_PROFILE_UUID`.
4. **Beszel login** → `GET /api/beszel/getkey` for the hub public key, `GET /api/beszel/universal-token` for the token (reuses an active one, otherwise mints a 1-hour ephemeral one; `BESZEL_PERMANENT_TOKEN=yes` makes it permanent).
5. **DNS** — creates the A record at reg.ru (see below).
6. **Docker** via `get.docker.com`, skipped if present.
7. **Kernel tuning** — see below.
8. **ufw** — rules added *before* `enable`, port 22 kept open until the new SSH port is verified.
9. **Waits for DNS** to propagate, querying `1.1.1.1` directly so a local negative cache doesn't mask success.
10. **selfsteal** — `install --force --domain <domain> --port 9443`.
11. **Certificates** — locates the cert Caddy just issued, inside its Docker volume.
12. **Remnanode** — `GET /api/keygen` → `SECRET_KEY` → `docker-compose.yml` → `up -d`, verified running. See [Panel versions](#panel-versions).
13. **Cert renewal watcher** — daily systemd timer, restarts the node when the cert changes.
14. **Registers the node** — `POST /api/nodes`.
15. **WARP** — warp-native, driven non-interactively.
16. **Beszel agent** — auto-registers itself with the hub.
17. **SSH → 2224** — verified, then port 22 is closed.

## DNS (reg.ru)

Uses [REG.API 2](https://www.reg.ru/reseller/api2doc): `zone/nop` to confirm the zone
is manageable, `zone/get_resource_records` to see what's there, `zone/remove_record`
to clear a stale A record, then `zone/add_alias` to point the label at the detected
public IPv4. Re-running with an already-correct record is a no-op.

**Two prerequisites**, both one-time:

1. The domain must use `ns1.reg.ru` / `ns2.reg.ru`. Zone management does nothing otherwise, and the script stops with that message rather than pretending it worked.
2. REG.API must be enabled at [account settings → API](https://www.reg.ru/user/account/#/settings/api/), **with the calling server's IP allowed**.

Point 2 is the awkward one for this use case. reg.ru checks the IP allowlist
*before* it checks the password, so a brand-new node fails immediately with
`ACCESS_DENIED_FROM_IP` — and the caller here is the new node itself, whose IP
changes every time you provision one. Either allow all addresses in the API
settings, or add each server's IP before running. The script detects this specific
error and tells you the exact IP to whitelist, and it happens before anything on
the server has been modified, so you can whitelist and re-run cleanly.

Set a **separate API password** in those settings rather than reusing your account
password.

Only an A record is created. IPv6/AAAA is out of scope.

## Panel versions

`GET /api/keygen` returns the node's key under different names depending on panel
version: `.response.pubKey` on 2.8.x and older, `.response.secretKey` on newer
builds. The value is byte-identical — a base64 payload of `nodeCertPem`,
`nodeKeyPem`, `caCertPem` and `jwtPublicKey` — and the node always reads it from
the `SECRET_KEY` environment variable regardless. The script accepts either field
and verifies the payload decodes with a `jwtPublicKey` before writing the compose
file. If neither field is present it reports which keys the panel *did* return.

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

## Beszel login

If you get **"The request doesn't satisfy the collection requirements to
authenticate"**, that is PocketBase rejecting the login before it ever checks the
password. From beszel's `collections.go`:

```go
usersCollection.PasswordAuth.Enabled = disablePasswordAuth != "true"
usersCollection.PasswordAuth.IdentityFields = []string{"email"}
```

So, in order of likelihood:

1. **The hub runs with `DISABLE_PASSWORD_AUTH=true`** — password auth is off on the `users` collection entirely (OIDC-only setups).
2. **You gave a username** — the only accepted identity field is the **email address**.
3. **The account is a superuser.** Superusers live in a different collection (`_superusers`). The script now tries that one too, but superusers cannot mint universal tokens, so enrolment stays manual.
4. **MFA is enabled** — the first factor returns a challenge, not a token, which cannot be completed unattended.

The script reports which of these applies and continues without beszel. To skip
the login altogether, pass the two values directly — both are on the hub, under
Settings → Tokens and the *Add system* dialog:

```bash
bkey='ssh-ed25519 AAAA...' btoken=<universal-token-uuid>
```

With a key but no token the agent still installs; you just add the system on the
hub by hand (host = your node domain, port 45876).

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

- Your Reality inbound in the panel must list the node domain in `serverNames` and point `dest` at `127.0.0.1:9443`. The script prints this reminder at the end.
- With `MANAGE_DNS=no`, the record you create must be **DNS-only**, not Cloudflare-proxied, or the panel cannot reach port 2222.

## Options

| Variable | Default | Effect |
|---|---|---|
| `MANAGE_DNS` | prompt | `no` skips reg.ru and asks for a full hostname |
| `REGRU_ZONE` / `REGRU_USER` / `REGRU_PASSWORD` | – | reg.ru zone and credentials |
| `NODE_SUBDOMAIN` | prompt | label only, or `@` for the zone apex |
| `NODE_DOMAIN` | derived | full hostname; required when `MANAGE_DNS=no` |
| `DNS_WAIT_SECONDS` | `300` | how long to wait for propagation |
| `PANEL_IP` | resolved from `PANEL_URL` | source IP allowed on port 2222 |
| `PANEL_EXTRA_HEADER` | – | extra header if the panel sits behind header auth, e.g. `"X-Api-Key: secret"` |
| `CONFIG_PROFILE_UUID` | – | skip the profile picker |
| `COUNTRY_CODE` | auto | node country code |
| `NODE_PORT` / `SSH_PORT` / `SELFSTEAL_PORT` / `BESZEL_PORT` | 2222 / 2224 / 9443 / 45876 | ports |
| `DISABLE_IPV6` | prompt | `yes` / `no` |
| `BESZEL_PERMANENT_TOKEN` | `no` | persist the universal token on the hub |
| `SKIP_WARP` | `no` | skip WARP |
| `SKIP_SSH_PORT` | `no` | leave SSH on port 22 |
