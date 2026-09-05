# Torrent blocking and speed shaping for Remnawave nodes

Date: 2026-09-05
Status: approved design, pending implementation

## Problem

Hosting providers ban servers that emit BitTorrent traffic. The fleet needs
torrent traffic blocked at the node without collateral damage to legitimate
traffic. Separately, a single client saturating a node's uplink degrades it for
everyone, so sustained heavy users must be shaped down.

Two requirements:

1. Block torrent traffic, and only torrent traffic.
2. A client pushing more than 100 Mbit/s for longer than 2 minutes is shaped to
   8 Mbit/s.

## Findings from the live fleet

Panel 2.8.1, 17 connected nodes, Xray 26.6.27–26.7.28, node 2.8.0–3.1.1.

A `Torrent Blocker` node plugin (uuid `6a4b3879-6fac-4dcb-9441-d4269134e149`)
already exists, is enabled with `blockDuration: 3600` and
`includeRuleTags: ["TORRENT_BY_DOMAIN", "TORRENT_BY_PORT"]`, and is assigned to
every node via `activePluginUuid`. Xray everywhere exceeds the plugin's 26.3.27
minimum. Sniffing is enabled on all 26 inbounds.

Despite that, the plugin has recorded **8 reports total, 0 in the last 24
hours**. Three separate causes:

### 1. The `TORRENT` outbound tag does not exist (primary cause)

`Steal_Configs`, `CDN_Xhttp`, `russia_in_other_out` and `other_in_internet_out`
all route bittorrent to `outboundTag: "TORRENT"`. None of them define an
outbound with that tag — their outbound lists are `[DIRECT, BLOCK, warp-out,
…]`.

Xray logs `app/dispatcher: non existing outTag` and falls back to the first
outbound, which is `DIRECT` in every profile. Detected torrent traffic is
therefore **forwarded to the internet**, not blackholed. The plugin's IP bans
still fire, which is why the report count is non-zero but the traffic never
stopped.

### 2. Missing and untagged rules

| Profile | State |
|---|---|
| `other_in_internet_out` | `bittorrent`→`TORRENT`, no `TORRENT_BY_DOMAIN`, no `TORRENT_BY_PORT` |
| `StealWHITELIST`, `BRIDGE_RU_IN` | `bittorrent`→`BLOCK`, untagged; traffic drops but no ban fires |
| `Balancer`, `TestNodes` | no torrent rule of any kind |

### 3. Xray only sniffs unencrypted BitTorrent

Clients with MSE/protocol-encryption enabled are not detected by the sniffer at
all. This gap cannot be closed in the panel; it needs packet-level rules on the
node.

### Out of scope: X-Forwarded-For on CDN nodes

Both XHTTP inbounds in `CDN_Xhttp` carry:

```json
"sockopt": { "trustedXForwardedFor": ["X-Forwarded-For"] }
```

`trustedXForwardedFor` is a **CIDR list of peer addresses permitted to set the
header**, not a header name. The current value cannot match any peer, so Xray
discards the header and records the CDN edge IP. Confirm on a node by grepping
Xray's log for `ignored potentially forged X-Forwarded-For`.

Consequence: on `RU-beget-cdn-01` and `expresshost_cdn_poland_01` the Torrent
Blocker will nftables-ban the **CDN edge address**, taking the node offline for
every user on it, the first time it fires.

Notes for whoever fixes this:

- The value must be the CDN/nginx edge ranges. `0.0.0.0/0` on a directly
  reachable inbound lets any client spoof `X-Forwarded-For` to get a third party
  banned or to evade shaping. If nginx runs on the node itself, `127.0.0.1/32`
  is correct.
- `X-Real-IP` is not parsed by Xray. Only `X-Forwarded-For`, plus Cloudflare's
  `CF-Connecting-IP`. See XTLS/Xray-core#6382.
- `VLESS_TCP_REALITY_CDN` is `network: "raw"` — no HTTP layer, so no header can
  work on it. Real client IP there requires PROXY protocol.

The owner has taken this fix. It is recorded here because it changes the risk
profile of the plugin, not because this work implements it.

## Design

Three layers. Each is useful alone; none depends on another completing.

### Layer 1 — Panel config profiles

Applied through the panel API, as one reviewable diff, after the owner approves
the exact JSON.

**Every profile** gains a blackhole outbound:

```json
{ "tag": "TORRENT", "protocol": "blackhole" }
```

Kept distinct from the existing `BLOCK` outbound so torrent drops stay
separable from other drops in logs, and so the plugin's rule-tag reporting is
unchanged.

**Profiles missing rules** gain the standard three, inserted directly after the
leading `BLOCK` rules to match the ordering already used in `Steal_Configs`:

```json
{ "protocol": ["bittorrent"], "outboundTag": "TORRENT" },
{ "domain": ["geosite:category-public-tracker"],
  "ruleTag": "TORRENT_BY_DOMAIN", "outboundTag": "TORRENT" },
{ "port": "6881-6889,51413,21413,17417,37305",
  "ruleTag": "TORRENT_BY_PORT", "outboundTag": "TORRENT" }
```

Per profile:

| Profile | Add `TORRENT` outbound | Rule changes |
|---|---|---|
| `Steal_Configs` | yes | none, already complete |
| `CDN_Xhttp` | yes | none, already complete |
| `russia_in_other_out` | yes | none, already complete |
| `other_in_internet_out` | yes | add `TORRENT_BY_DOMAIN`, `TORRENT_BY_PORT` |
| `StealWHITELIST` | yes | repoint bittorrent rule to `TORRENT`; add both tagged rules |
| `BRIDGE_RU_IN` | yes | repoint bittorrent rule to `TORRENT`; add both tagged rules |
| `Balancer` | yes | add all three |
| `TestNodes` | yes | add all three |

### Layer 2 — `torrent-guard`, node-side nftables

Catches what the sniffer misses, including encrypted BitTorrent. Own table,
`policy accept` with explicit drops, so it cannot interfere with ufw or with the
plugin's own table.

Hooked on `output`, so it sees traffic the node originates — including traffic
routed into WARP, which traverses `output` before encapsulation. It never
inspects client-facing traffic, so it is indifferent to whether a node sits
behind a CDN.

```
table inet rw_torrent_guard {
    set bt_ports { type inet_service; flags interval;
                   elements = { 6881-6889, 51413, 21413, 17417, 37305 } }

    chain out {
        type filter hook output priority filter + 10; policy accept;

        oifname "lo" accept
        udp dport 53 accept
        tcp dport 53 accept

        # Anything answering a connection opened to us — clients, panel,
        # beszel, ssh. A connection-direction test rather than a port list:
        # a port list has to widen as inbounds are added, and once it overlaps
        # the ephemeral range (32768-60999) it accepts the node's own outbound
        # connections and everything below becomes unreachable.
        ct direction reply accept

        # UDP tracker connect: magic 0x41727101980, 8 bytes at UDP payload start
        meta l4proto udp @th,64,64 0x0000041727101980 counter drop comment "udp-tracker"

        # DHT query  "d1:ad2:i"
        meta l4proto udp @th,64,64 0x64313a6164323a69 counter drop comment "dht"
        # DHT reply  "d1:rd2:i"
        meta l4proto udp @th,64,64 0x64313a7264323a69 counter drop comment "dht"

        # Port rules apply to the first packet only. The connection never
        # establishes, and any pre-existing flow is left alone.
        ct state new tcp dport @bt_ports counter drop comment "bt-ports"
        ct state new udp dport @bt_ports counter drop comment "bt-ports"
    }
}
```

Offsets: `th` is the transport header, the UDP header is 8 bytes, so `@th,64,64`
is the first 8 bytes of UDP payload.

Payload matching stays unconditional because DHT traffic is stateless UDP where
the interesting packets are not all `ct state new`.

Counters are anonymous and tagged by comment rather than declared as named
objects. A rule cannot reference a named counter created in the same
transaction: nft resolves stateful objects against the committed generation, so
each such rule fails with ENOENT. Confirmed on Ubuntu 24.04, kernel 6.1.182,
nft 1.0.9. Named *sets* in the same batch resolve fine — it is specific to
stateful objects. `guard_status` groups the anonymous counters by comment to
report the same three totals.

It drops silently and reports nothing to the panel. A false positive therefore
costs one broken connection, not a locked-out customer. The TCP BitTorrent
handshake is deliberately not string-matched here — Xray's sniffer already
covers the unencrypted case that a string match could catch.

### Layer 3 — `rw-shaper`, nftables measures and tc enforces

**Measure.** One nftables set of client addresses with per-element byte
counters, fed from both directions on the WAN interface, restricted to the
client-facing ports and to the original/reply direction of connections clients
opened. Direction is what makes a wide port range safe: metering
`20000-50000` on port alone also catches replies from sites xray fetched, since
the node's ephemeral ports overlap it, filing those bytes against the remote
server's address.

```
table inet rw_shaper {
    set clients {
        type ipv4_addr
        size 65535
        flags dynamic,timeout
        timeout 10m
        counter
    }
    chain meter_in {
        type filter hook prerouting priority -150; policy accept;
        iifname $WAN ct direction original tcp dport { $PORTS } update @clients { ip saddr counter }
        iifname $WAN ct direction original udp dport { $PORTS } update @clients { ip saddr counter }
    }
    chain meter_out {
        type filter hook postrouting priority -150; policy accept;
        oifname $WAN ct direction reply tcp sport { $PORTS } update @clients { ip daddr counter }
        oifname $WAN ct direction reply udp sport { $PORTS } update @clients { ip daddr counter }
    }
}
```

**Decide.** A bash + jq daemon (`jq` is already a preflight dependency) on a 10 s
tick, reading `nft -j list set inet rw_shaper clients`.

| Parameter | Value | Meaning |
|---|---|---|
| tick | 10 s | poll interval |
| trigger rate | 12,500,000 B/s | 100 Mbit/s, combined both directions |
| trigger ticks | 12 | 2 minutes sustained |
| cap | 8 Mbit/s | applied per direction |
| release rate | 500,000 B/s | below 4 Mbit/s counts as quiet |
| release ticks | 30 | 5 minutes quiet before release |

Once shaped, a client that keeps pulling sits at the 8 Mbit/s cap, so release is
keyed on falling well below the cap rather than below the trigger.

Counter deltas are computed per tick. An element that ages out of the set and
reappears has a counter lower than the stored previous value; that is treated as
a fresh start, not a negative delta.

**Enforce.** HTB on the WAN device for download, HTB on `ifb0` fed by a `mirred`
ingress redirect for upload. The daemon adds a dedicated class plus a `u32`
filter per offending address and tears both down on release.

No fwmark is used: tc ingress runs before netfilter, so nftables marks are not
available on the ifb path. Matching addresses directly in `u32` keeps both
directions consistent, and the shaped set is small enough that filter count is
not a concern.

Upload shaping is behind `SHAPE_UPLOAD` (default `yes`). Turning it off skips
the ingress qdisc and `mirred` redirect entirely, which matters on a busy
1 Gbit node because the redirect puts all inbound traffic through `ifb0`.

**Safety interlocks.** The daemon refuses to shape an address that:

- appears in `IGNORE_IPS` (panel IP, beszel hub, current SSH peer, admin list);
- is loopback, private, or the node's own address;
- currently holds more than `MAX_CONNS` concurrent conntrack entries, default
  200 — the signature of a CDN edge or a large CGNAT pool, not one user.

The conntrack check runs only at the moment a shape is about to be applied,
which is rare, never on the 10 s tick. Counting entries for every tracked
address each tick would mean walking the whole conntrack table on a busy node.

Total shaped addresses are capped at `MAX_SHAPED`, default 64.

**CDN nodes.** Per-client packet shaping is impossible behind a CDN: the source
address on the wire is the edge, and `X-Forwarded-For` lives in the TCP payload
where tc cannot reach it. `RU-beget-cdn-01` and `expresshost_cdn_poland_01` set
`SKIP_SHAPER=yes`. The `MAX_CONNS` interlock is a second line of defence if that
is forgotten. Both nodes still get Layers 1 and 2 in full.

**Files.**

| Path | Purpose |
|---|---|
| `/usr/local/bin/rw-shaper` | daemon |
| `/etc/rw-shaper.conf` | tunables |
| `/run/rw-shaper/state` | per-address counters and class allocation |
| `/etc/systemd/system/rw-shaper.service` | `Restart=always`, `ExecStop` tears down tc and the nft table |

### Integration with `install-node.sh`

`nftables` joins the preflight package list; it is a hard requirement of the
Remnawave plugin as well as of both new layers.

Menu gains:

```
   16)  Torrent guard             nftables rules for DHT, UDP trackers, BT ports
   17)  Speed shaper              >100 Mbit/s for 2 min -> 8 Mbit/s
   18)  Guard status              counters, shaped clients, drop stats
```

Unlike zapret, both run as part of `run_all`. They are non-interactive, they
scope themselves to their own nftables tables, and they are wanted on every
node. Opt out with `SKIP_TORRENT_GUARD=yes` / `SKIP_SHAPER=yes`.

Both follow the established conventions: `step`/`ok`/`warn`/`soft_fail`,
idempotent re-runs, `|| true` in `run_all` so a failure is recorded in
`FAILED_STEPS` without aborting the install.

## Verification

Points that must be checked on a real node during implementation rather than
assumed:

1. **nftables set element counters.** Resolved, and the original assumption was
   wrong. Declaring `counter` in the set definition covers *static* elements
   only; an element added from the packet path gets a counter only if the
   update statement asks for one. `update @clients { ip saddr }` therefore
   created elements with no counter at all, and the reader — which selects on
   `.counter != null` — saw an empty list while the set itself filled up
   normally. The correct form is `update @clients { ip saddr counter }`.
2. **Raw payload offsets.** Confirm `@th,64,64` matches the intended bytes for
   UDP on the target kernel, by generating a DHT query and watching the counter.
   Note that `nft -c -f` is not the tool for this. Check mode cannot resolve
   named counters or sets that the same batch is creating, and a
   `table` + `delete table` prelude breaks that resolution even outside check
   mode — every referencing rule fails with ENOENT. Confirmed on Ubuntu 24.04,
   kernel 6.1.182, nft 1.0.9. The table is deleted imperatively beforehand and
   the file is loaded for real; nftables applies a file as one atomic
   transaction, so a failed load commits nothing.
3. **Coexistence.** Confirm the two new tables do not disturb ufw, Docker's
   chains, or the plugin's table: `nft list ruleset` before and after, plus a
   connectivity check from a client.
4. **tc teardown.** Confirm `ExecStop` leaves no qdisc behind, so a restart does
   not stack qdiscs.
5. **Layer 1 effect.** After the panel diff, confirm `non existing outTag` stops
   appearing in Xray's log and that the plugin's 24-hour report count rises.

## Explicitly not doing

- **Connection-fanout heuristics.** Blocking clients that open many concurrent
  connections to many peers would catch encrypted BitTorrent, but it also
  catches legitimate applications. The requirement is to block torrent traffic
  only, so heuristics that trade false positives for coverage are excluded.
- **TCP payload string matching for the BitTorrent handshake.** Xray's sniffer
  already covers the unencrypted case, and `xt_string` on every outbound TCP
  packet is a real cost for no additional coverage.
- **Per-subscription-user shaping.** Rejected in favour of per-client-IP: it
  would couple the daemon to Xray log parsing and break when logging is off.
- **The XFF fix.** Owner is handling it; see above.
