#!/usr/bin/env bash
#
# install-node.sh — one-shot Remnawave node provisioner.
#
#   bash <(curl -Ls https://raw.githubusercontent.com/kiineld/nodesetuper/main/install-node.sh)
#
# Provisions a fresh Debian/Ubuntu VPS into a fully registered Remnawave node:
# kernel tuning + BBR, ufw, selfsteal (Caddy), Let's Encrypt certs wired into
# Xray, WARP, beszel agent, SSH hardening, and registration with the panel.
#
# Every prompt can be pre-answered with an environment variable, so the script
# is equally usable unattended:
#
#   NODE_DOMAIN=de1.example.com NODE_NAME=DE-1 REMNA_TOKEN=... \
#   BESZEL_EMAIL=me@example.com BESZEL_PASSWORD=... DISABLE_IPV6=yes \
#   bash install-node.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# CONFIG — edit these two once, then the script only ever asks for per-node data
# ---------------------------------------------------------------------------

PANEL_URL="${PANEL_URL:-}"              # e.g. https://panel.example.com  (no trailing slash)
BESZEL_HUB_URL="${BESZEL_HUB_URL:-}"    # e.g. https://beszel.example.com (no trailing slash)

# Ports. These match the ufw rules opened below.
NODE_PORT="${NODE_PORT:-2222}"          # panel -> node internal API
SSH_PORT="${SSH_PORT:-2224}"            # new SSH port
SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"
BESZEL_PORT="${BESZEL_PORT:-45876}"

# Optional knobs
PANEL_EXTRA_HEADER="${PANEL_EXTRA_HEADER:-}"   # e.g. "X-Api-Key: secret" if the panel sits behind header auth
PANEL_IP="${PANEL_IP:-}"                       # override the auto-resolved panel IP for the NODE_PORT rule
CONFIG_PROFILE_UUID="${CONFIG_PROFILE_UUID:-}" # skip the config-profile picker
COUNTRY_CODE="${COUNTRY_CODE:-}"               # auto-detected if empty
DISABLE_IPV6="${DISABLE_IPV6:-}"               # yes | no  (prompted if empty)
BESZEL_PERMANENT_TOKEN="${BESZEL_PERMANENT_TOKEN:-no}"  # yes = persist the universal token on the hub
SKIP_WARP="${SKIP_WARP:-no}"
SKIP_SSH_PORT="${SKIP_SSH_PORT:-no}"

INSTALL_DIR="/opt/remnanode"
XRAY_SSL_DIR="/var/lib/remnawave/configs/xray/ssl"
LOG_FILE="/var/log/remnanode-autoinstall.log"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
    C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'
else
    C_RESET=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""
fi

UFW_ENABLED_BY_US=no
SSH_MIGRATED=no
PUBLIC_IP=""
CERT_PATH=""
KEY_PATH=""
EXISTING_NODE_UUID=""
REGISTERED_UUID=""
ACTIVE_INBOUNDS_JSON="[]"

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s==> [%02d] %s%s\n' "$C_BLU" "$STEP_NO" "$*" "$C_RESET"; }
info() { printf '     %s\n' "$*"; }
ok()   { printf '     %s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '     %s!%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

on_error() {
    local exit_code=$? line=$1
    printf '\n%s✗ failed at line %s (exit %s)%s\n' "$C_RED" "$line" "$exit_code" "$C_RESET" >&2
    printf '  full log: %s\n' "$LOG_FILE" >&2
    if [[ "${UFW_ENABLED_BY_US:-no}" == "yes" && "${SSH_MIGRATED:-no}" != "yes" ]]; then
        printf '  %sport 22 is still open — your current SSH access is intact.%s\n' "$C_YEL" "$C_RESET" >&2
    fi
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

have() { command -v "$1" >/dev/null 2>&1; }

# Prompts go straight to the terminal. stdout is piped through tee for logging,
# and tee does not flush a prompt that has no trailing newline.
prompt() { printf '     %s' "$*" > /dev/tty; }

ask() {  # ask <varname> <prompt> [default]
    local var=$1 text=$2 default=${3:-} answer
    if [[ -n "${!var:-}" ]]; then return 0; fi
    while :; do
        if [[ -n "$default" ]]; then
            prompt "$text [$default]: "
            read -r answer < /dev/tty || true
            answer="${answer:-$default}"
        else
            prompt "$text: "
            read -r answer < /dev/tty || true
        fi
        [[ -n "$answer" ]] && break
        warn "value required"
    done
    printf -v "$var" '%s' "$answer"
}

ask_secret() {  # ask_secret <varname> <prompt>
    local var=$1 text=$2 answer
    if [[ -n "${!var:-}" ]]; then return 0; fi
    while :; do
        prompt "$text: "
        read -r -s answer < /dev/tty || true
        printf '\n' > /dev/tty
        [[ -n "$answer" ]] && break
        warn "value required"
    done
    printf -v "$var" '%s' "$answer"
}

ask_yes_no() {  # ask_yes_no <varname> <prompt> <default yes|no>
    local var=$1 text=$2 default=$3 answer
    if [[ -n "${!var:-}" ]]; then
        case "${!var,,}" in
            y|yes|true|1) printf -v "$var" '%s' "yes" ;;
            *)            printf -v "$var" '%s' "no" ;;
        esac
        return 0
    fi
    local hint="y/N"; [[ "$default" == "yes" ]] && hint="Y/n"
    prompt "$text [$hint]: "
    read -r answer < /dev/tty || true
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) printf -v "$var" '%s' "yes" ;;
        *)     printf -v "$var" '%s' "no" ;;
    esac
}

strip_slash() { printf '%s' "${1%/}"; }

# ---------------------------------------------------------------------------
# Remnawave panel API
# ---------------------------------------------------------------------------

RW_BODY=""; RW_STATUS=""

rw_api() {  # rw_api <METHOD> <path> [json body]
    local method=$1 path=$2 body=${3:-} raw
    local args=(-sS --max-time 30 -X "$method"
                -H "Authorization: Bearer ${REMNA_TOKEN}"
                -H "Content-Type: application/json"
                -H "Accept: application/json")
    [[ -n "$PANEL_EXTRA_HEADER" ]] && args+=(-H "$PANEL_EXTRA_HEADER")
    [[ -n "$body" ]] && args+=(--data-binary "$body")
    raw=$(curl "${args[@]}" -w $'\n%{http_code}' "${PANEL_URL}${path}") || return 1
    RW_STATUS="${raw##*$'\n'}"
    RW_BODY="${raw%$'\n'*}"
}

rw_ok() { [[ "$RW_STATUS" =~ ^2 ]]; }

rw_error() {  # human-readable panel error
    local msg
    msg=$(printf '%s' "$RW_BODY" | jq -r '.message // .error // empty' 2>/dev/null || true)
    [[ -z "$msg" ]] && msg=$(printf '%s' "$RW_BODY" | head -c 300)
    printf 'HTTP %s — %s' "$RW_STATUS" "$msg"
}

# ---------------------------------------------------------------------------
# Beszel hub API (PocketBase)
# ---------------------------------------------------------------------------

BESZEL_AUTH=""; BESZEL_KEY=""; BESZEL_TOKEN=""

bz_get() {  # bz_get <path>
    curl -sS --max-time 30 -H "Authorization: ${BESZEL_AUTH}" -H "Accept: application/json" \
        "${BESZEL_HUB_URL}$1"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

preflight() {
    step "Preflight"
    [[ $EUID -eq 0 ]] || die "run as root"
    [[ -r /etc/os-release ]] || die "unsupported OS (no /etc/os-release)"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*) ;;
        *) die "this script targets Debian/Ubuntu, found: ${PRETTY_NAME:-unknown}" ;;
    esac
    info "OS: ${PRETTY_NAME:-unknown}  kernel: $(uname -r)"

    export DEBIAN_FRONTEND=noninteractive
    local need=()
    have curl || need+=(curl)
    have jq   || need+=(jq)
    have ufw  || need+=(ufw)
    have dig  || need+=(dnsutils)
    have ss   || need+=(iproute2)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || need+=(ca-certificates)
    if ((${#need[@]})); then
        info "installing: ${need[*]}"
        apt-get update -qq
        apt-get install -y -qq "${need[@]}" >/dev/null
    fi

    PUBLIC_IP="$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
    [[ -n "$PUBLIC_IP" ]] && info "public IPv4: $PUBLIC_IP" || warn "could not detect public IPv4"
    ok "preflight done"
}

gather_input() {
    step "Configuration"
    ask PANEL_URL "Remnawave panel URL (https://panel.example.com)"
    ask BESZEL_HUB_URL "Beszel hub URL (https://beszel.example.com)"
    PANEL_URL="$(strip_slash "$PANEL_URL")"
    BESZEL_HUB_URL="$(strip_slash "$BESZEL_HUB_URL")"

    ask NODE_DOMAIN "Node domain (selfsteal + panel node address)"
    ask NODE_NAME "Node name (panel + beszel)"
    ask_secret REMNA_TOKEN "Remnawave API token"
    ask BESZEL_EMAIL "Beszel hub email (a regular user, NOT a superuser)"
    ask_secret BESZEL_PASSWORD "Beszel hub password"
    ask_yes_no DISABLE_IPV6 "Disable IPv6 on this server?" "no"

    [[ ${#NODE_NAME} -ge 3 && ${#NODE_NAME} -le 30 ]] \
        || die "node name must be 3-30 characters (panel constraint)"

    local resolved
    resolved="$(dig +short A "$NODE_DOMAIN" | grep -E '^[0-9.]+$' | head -1 || true)"
    if [[ -z "$resolved" ]]; then
        warn "$NODE_DOMAIN does not resolve to an A record yet — ACME will fail"
    elif [[ -n "${PUBLIC_IP:-}" && "$resolved" != "$PUBLIC_IP" ]]; then
        warn "$NODE_DOMAIN resolves to $resolved but this host is $PUBLIC_IP"
        warn "if that is a Cloudflare proxy IP, switch the record to DNS-only or the panel cannot reach port $NODE_PORT"
    else
        ok "$NODE_DOMAIN -> $resolved"
    fi

    if [[ -z "$PANEL_IP" ]]; then
        local panel_host="${PANEL_URL#*://}"; panel_host="${panel_host%%/*}"; panel_host="${panel_host%%:*}"
        PANEL_IP="$(dig +short A "$panel_host" | grep -E '^[0-9.]+$' | head -1 || true)"
    fi
    [[ -n "$PANEL_IP" ]] && ok "panel IP: $PANEL_IP" \
        || warn "could not resolve panel IP — port $NODE_PORT will be opened to all sources"

    if [[ -z "$COUNTRY_CODE" ]]; then
        COUNTRY_CODE="$(curl -sS --max-time 8 "https://ipapi.co/${PUBLIC_IP:-}/country" 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
    fi
    [[ ${#COUNTRY_CODE} -eq 2 ]] || COUNTRY_CODE="XX"
    COUNTRY_CODE="${COUNTRY_CODE^^}"
    info "country code: $COUNTRY_CODE"
}

validate_panel() {
    step "Validating Remnawave API token"
    rw_api GET /api/nodes || die "cannot reach $PANEL_URL"
    rw_ok || die "panel rejected the token: $(rw_error)"
    local count
    count=$(printf '%s' "$RW_BODY" | jq -r '.response | length' 2>/dev/null || echo 0)
    ok "token valid — panel currently has $count node(s)"

    EXISTING_NODE_UUID="$(printf '%s' "$RW_BODY" \
        | jq -r --arg n "$NODE_NAME" --arg a "$NODE_DOMAIN" \
          '.response[] | select(.name == $n or .address == $a) | .uuid' 2>/dev/null | head -1 || true)"
    if [[ -n "$EXISTING_NODE_UUID" ]]; then
        warn "a node named '$NODE_NAME' or addressed '$NODE_DOMAIN' already exists ($EXISTING_NODE_UUID)"
        warn "it will be left untouched; this run will reinstall the node software only"
    fi
}

resolve_config_profile() {
    step "Resolving config profile"
    rw_api GET /api/config-profiles || die "cannot list config profiles"
    rw_ok || die "cannot list config profiles: $(rw_error)"

    local total
    total=$(printf '%s' "$RW_BODY" | jq -r '.response.total // (.response.configProfiles | length)')
    [[ "$total" -gt 0 ]] || die "no config profiles exist in the panel — create one first"

    if [[ -z "$CONFIG_PROFILE_UUID" ]]; then
        if [[ "$total" -eq 1 ]]; then
            CONFIG_PROFILE_UUID=$(printf '%s' "$RW_BODY" | jq -r '.response.configProfiles[0].uuid')
            info "only one profile: $(printf '%s' "$RW_BODY" | jq -r '.response.configProfiles[0].name')"
        else
            echo
            printf '%s' "$RW_BODY" | jq -r '.response.configProfiles | to_entries[] | "     \(.key + 1)) \(.value.name)  [\(.value.uuid)]"'
            echo
            local choice
            while :; do
                read -r -p "     select config profile [1-$total]: " choice < /dev/tty || true
                [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )) && break
                warn "enter a number between 1 and $total"
            done
            CONFIG_PROFILE_UUID=$(printf '%s' "$RW_BODY" | jq -r ".response.configProfiles[$((choice - 1))].uuid")
        fi
    fi

    rw_api GET "/api/config-profiles/${CONFIG_PROFILE_UUID}/inbounds" || die "cannot list inbounds"
    rw_ok || die "cannot list inbounds for $CONFIG_PROFILE_UUID: $(rw_error)"
    ACTIVE_INBOUNDS_JSON=$(printf '%s' "$RW_BODY" | jq -c '[.response.inbounds[].uuid]')
    local n; n=$(printf '%s' "$ACTIVE_INBOUNDS_JSON" | jq 'length')
    [[ "$n" -gt 0 ]] || die "config profile $CONFIG_PROFILE_UUID has no inbounds"
    ok "profile $CONFIG_PROFILE_UUID with $n inbound(s)"
    printf '%s' "$RW_BODY" | jq -r '.response.inbounds[] | "       - \(.tag)  (\(.type))"'
}

beszel_login() {
    step "Authenticating with beszel hub"
    local payload resp
    payload=$(jq -nc --arg i "$BESZEL_EMAIL" --arg p "$BESZEL_PASSWORD" '{identity:$i, password:$p}')
    resp=$(curl -sS --max-time 30 -X POST -H "Content-Type: application/json" \
        --data-binary "$payload" \
        "${BESZEL_HUB_URL}/api/collections/users/auth-with-password" 2>/dev/null || true)

    BESZEL_AUTH=$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null || true)
    [[ -n "$BESZEL_AUTH" ]] || die "beszel login failed: $(printf '%s' "$resp" | jq -r '.message // .' 2>/dev/null | head -c 200)"
    ok "logged in as $BESZEL_EMAIL"

    BESZEL_KEY=$(bz_get /api/beszel/getkey | jq -r '.key // empty')
    [[ -n "$BESZEL_KEY" ]] || die "could not read the hub public key from /api/beszel/getkey"
    ok "hub public key retrieved"

    local tok_resp
    tok_resp=$(bz_get /api/beszel/universal-token)
    if [[ "$(printf '%s' "$tok_resp" | jq -r '.active // false')" == "true" ]]; then
        BESZEL_TOKEN=$(printf '%s' "$tok_resp" | jq -r '.token')
        info "reusing the universal token already active on the hub"
    else
        local q="/api/beszel/universal-token?enable=1"
        [[ "${BESZEL_PERMANENT_TOKEN,,}" == "yes" ]] && q+="&permanent=1"
        tok_resp=$(bz_get "$q")
        BESZEL_TOKEN=$(printf '%s' "$tok_resp" | jq -r '.token // empty')
        [[ -n "$BESZEL_TOKEN" ]] || die "could not obtain a universal token (superusers cannot use them — use a regular user account)"
        if [[ "$(printf '%s' "$tok_resp" | jq -r '.permanent // false')" == "true" ]]; then
            info "enabled a permanent universal token on the hub"
        else
            info "enabled a 1-hour ephemeral universal token"
        fi
    fi
    ok "universal token ready"
}

install_docker() {
    step "Docker"
    if have docker && docker compose version >/dev/null 2>&1; then
        ok "already installed ($(docker --version | cut -d, -f1))"
        return
    fi
    curl -fsSL https://get.docker.com | sh >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
    docker compose version >/dev/null 2>&1 || die "docker compose plugin missing after install"
    ok "installed"
}

tune_kernel() {
    step "Kernel & network tuning"

    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        warn "this kernel does not offer BBR — congestion control left at default"
    else
        grep -qx 'tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf
    fi

    cat > /etc/sysctl.d/99-remnanode-tuning.conf <<'SYSCTL'
# Managed by install-node.sh — tuned for an Xray/VPN edge node.

# Congestion control and queueing. fq is what BBR is designed to pace against.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket buffers. Large receive buffers matter a lot for QUIC/UDP 443, which
# is handled in userspace and drops silently when the kernel buffer overflows.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Loss and MTU behaviour. mtu_probing rescues connections through paths that
# black-hole ICMP fragmentation-needed (common once ICMP echo is disabled).
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

# Connection capacity — a node fans out to thousands of concurrent sockets.
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3

# Forwarding, needed for WARP and any routed outbound.
net.ipv4.ip_forward = 1

fs.file-max = 1048576
SYSCTL

    # ICMP echo off (requested). Kept in its own file so re-runs never stack duplicates.
    echo 'net.ipv4.icmp_echo_ignore_all = 1' > /etc/sysctl.d/99-remnanode-icmp.conf

    if [[ "$DISABLE_IPV6" == "yes" ]]; then
        cat > /etc/sysctl.d/99-remnanode-ipv6.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
        [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
        info "IPv6 disabled"
    else
        rm -f /etc/sysctl.d/99-remnanode-ipv6.conf
        [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
        info "IPv6 left enabled"
    fi

    sysctl --system >/dev/null 2>&1 || warn "some sysctl keys were rejected by this kernel (see $LOG_FILE)"

    # File descriptor ceilings for xray and the docker daemon.
    cat > /etc/security/limits.d/99-remnanode.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
    mkdir -p /etc/systemd/system.conf.d
    printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > /etc/systemd/system.conf.d/99-remnanode-nofile.conf
    systemctl daemon-reexec >/dev/null 2>&1 || true

    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    if [[ "$cc" == "bbr" && "$qd" == "fq" ]]; then
        ok "congestion control = bbr, qdisc = fq"
    else
        warn "congestion control = $cc, qdisc = $qd (expected bbr/fq)"
    fi
    ok "ICMP echo disabled, limits raised"
}

configure_ufw() {
    step "Firewall (ufw)"
    # Deliberately not resetting: a re-run must not wipe rules you added by hand.
    # `ufw allow` is idempotent, so re-applying the set below is safe.
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    # 22 stays open until the new SSH port is proven to work.
    ufw allow 22/tcp comment 'ssh (temporary, removed after migration)' >/dev/null
    ufw allow "${SSH_PORT}/tcp" comment 'ssh' >/dev/null
    ufw allow 80/tcp   comment 'acme / selfsteal http' >/dev/null
    ufw allow 443/tcp  comment 'xray reality' >/dev/null
    ufw allow 443/udp  comment 'xray quic' >/dev/null
    ufw allow "${BESZEL_PORT}/tcp" comment 'beszel agent' >/dev/null

    if [[ -n "$PANEL_IP" ]]; then
        ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'remnawave panel' >/dev/null
        info "port $NODE_PORT restricted to $PANEL_IP"
    else
        ufw allow "${NODE_PORT}/tcp" comment 'remnawave panel (UNRESTRICTED)' >/dev/null
        warn "port $NODE_PORT is open to the internet — set PANEL_IP and re-run to restrict it"
    fi

    ufw --force enable >/dev/null
    UFW_ENABLED_BY_US=yes
    ok "enabled"
    ufw status numbered | sed 's/^/       /'
}

install_selfsteal() {
    step "Selfsteal (Caddy masquerade site)"
    if docker ps --format '{{.Names}}' | grep -qi 'caddy'; then
        info "a caddy container is already running — reconfiguring"
    fi
    bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install \
        --force --domain "$NODE_DOMAIN" --port "$SELFSTEAL_PORT" \
        || die "selfsteal install failed"
    ok "installed on port $SELFSTEAL_PORT for $NODE_DOMAIN"
}

# Locate the Let's Encrypt cert Caddy issued for our domain, inside its data volume.
locate_certs() {
    step "Locating TLS certificate issued by selfsteal"
    CERT_PATH=""; KEY_PATH=""

    local vol=""
    for name in $(docker ps --format '{{.Names}}' | grep -i caddy || true); do
        vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$name" 2>/dev/null || true)
        [[ -n "$vol" ]] && break
    done
    [[ -z "$vol" ]] && for cand in caddy_caddy_data caddy_data; do
        docker volume inspect "$cand" >/dev/null 2>&1 && { vol="$cand"; break; }
    done
    if [[ -z "$vol" ]]; then
        warn "could not find the Caddy data volume — continuing without TLS certs"
        return 0
    fi

    local mp
    mp=$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)
    [[ -d "$mp" ]] || { warn "Caddy volume $vol has no readable mountpoint — continuing without TLS certs"; return 0; }
    info "caddy data volume: $vol"

    # ACME issuance is asynchronous; the CA directory name varies (LE, ZeroSSL),
    # so glob it rather than hardcoding acme-v02.api.letsencrypt.org-directory.
    local waited=0
    while (( waited < 120 )); do
        CERT_PATH=$(find "$mp/caddy/certificates" -type f -path "*/${NODE_DOMAIN}/${NODE_DOMAIN}.crt" 2>/dev/null | head -1 || true)
        [[ -n "$CERT_PATH" ]] && break
        sleep 5; waited=$((waited + 5))
        (( waited % 30 == 0 )) && info "waiting for ACME issuance... ${waited}s"
    done

    if [[ -z "$CERT_PATH" ]]; then
        warn "no certificate for $NODE_DOMAIN after ${waited}s"
        warn "Xray will start without TLS certs; re-run this script once the cert exists"
        return 0
    fi
    KEY_PATH="${CERT_PATH%.crt}.key"
    [[ -f "$KEY_PATH" ]] || { warn "found $CERT_PATH but no matching .key — continuing without TLS certs"; CERT_PATH=""; return 0; }

    mkdir -p "$XRAY_SSL_DIR"
    ok "cert: $CERT_PATH"
}

install_remnanode() {
    step "Remnawave node container"
    rw_api GET /api/keygen || die "cannot reach /api/keygen"
    rw_ok || die "cannot fetch SECRET_KEY: $(rw_error)"
    local secret
    secret=$(printf '%s' "$RW_BODY" | jq -r '.response.secretKey // empty')
    [[ -n "$secret" ]] || die "panel returned no secretKey"
    ok "SECRET_KEY retrieved"

    mkdir -p "$INSTALL_DIR" /var/log/remnanode

    {
        echo "services:"
        echo "  remnanode:"
        echo "    container_name: remnanode"
        echo "    hostname: remnanode"
        echo "    image: remnawave/node:latest"
        echo "    restart: always"
        echo "    network_mode: host"
        echo "    environment:"
        echo "      - NODE_PORT=${NODE_PORT}"
        echo "      - SECRET_KEY=${secret}"
        echo "    ulimits:"
        echo "      nofile:"
        echo "        soft: 1048576"
        echo "        hard: 1048576"
        echo "    volumes:"
        echo "      - /var/log/remnanode:/var/log/remnanode"
        if [[ -n "$CERT_PATH" ]]; then
            # Bind the individual files: certmagic rewrites them in place on
            # renewal, so the inode survives and the mount stays valid.
            echo "      - ${CERT_PATH}:${XRAY_SSL_DIR}/cert.pem:ro"
            echo "      - ${KEY_PATH}:${XRAY_SSL_DIR}/key.pem:ro"
        fi
        echo "    logging:"
        echo "      driver: json-file"
        echo "      options:"
        echo "        max-size: \"30m\""
        echo "        max-file: \"5\""
    } > "$INSTALL_DIR/docker-compose.yml"
    chmod 600 "$INSTALL_DIR/docker-compose.yml"

    cat > /etc/logrotate.d/remnanode <<'ROTATE'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
ROTATE

    ( cd "$INSTALL_DIR" && docker compose down --remove-orphans >/dev/null 2>&1 || true )
    ( cd "$INSTALL_DIR" && docker compose up -d ) >/dev/null

    local waited=0
    while (( waited < 60 )); do
        [[ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || echo false)" == "true" ]] && break
        sleep 3; waited=$((waited + 3))
    done
    [[ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null || echo false)" == "true" ]] \
        || die "remnanode container did not start — check: docker logs remnanode"
    ok "container running, listening on $NODE_PORT"
    [[ -n "$CERT_PATH" ]] && ok "TLS cert mounted at $XRAY_SSL_DIR/cert.pem"
}

install_cert_watcher() {
    [[ -z "$CERT_PATH" ]] && return 0
    step "Certificate renewal watcher"

    cat > /usr/local/bin/remnanode-cert-watch <<WATCH
#!/usr/bin/env bash
# Restart the node when the mounted certificate changes, so Xray picks up the
# renewed material instead of serving the expired one until the next reboot.
set -euo pipefail
CERT="${CERT_PATH}"
STATE=/var/lib/remnanode-cert.sha256
[[ -f "\$CERT" ]] || exit 0
NOW=\$(sha256sum "\$CERT" | cut -d' ' -f1)
if [[ ! -f "\$STATE" ]] || [[ "\$(cat "\$STATE")" != "\$NOW" ]]; then
    printf '%s' "\$NOW" > "\$STATE"
    cd ${INSTALL_DIR} && docker compose restart remnanode
    logger -t remnanode-cert-watch "certificate changed, remnanode restarted"
fi
WATCH
    chmod +x /usr/local/bin/remnanode-cert-watch
    sha256sum "$CERT_PATH" | cut -d' ' -f1 > /var/lib/remnanode-cert.sha256

    cat > /etc/systemd/system/remnanode-cert-watch.service <<'UNIT'
[Unit]
Description=Restart remnanode when its TLS certificate is renewed
[Service]
Type=oneshot
ExecStart=/usr/local/bin/remnanode-cert-watch
UNIT

    cat > /etc/systemd/system/remnanode-cert-watch.timer <<'UNIT'
[Unit]
Description=Daily check for a renewed remnanode TLS certificate
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now remnanode-cert-watch.timer >/dev/null 2>&1
    ok "daily renewal check installed"
}

register_node() {
    step "Registering node with the panel"
    if [[ -n "${EXISTING_NODE_UUID:-}" ]]; then
        warn "skipping — node already registered as $EXISTING_NODE_UUID"
        return 0
    fi

    local payload
    payload=$(jq -nc \
        --arg name "$NODE_NAME" \
        --arg address "$NODE_DOMAIN" \
        --argjson port "$NODE_PORT" \
        --arg cc "$COUNTRY_CODE" \
        --arg profile "$CONFIG_PROFILE_UUID" \
        --argjson inbounds "$ACTIVE_INBOUNDS_JSON" \
        '{name:$name, address:$address, port:$port, countryCode:$cc,
          isTrafficTrackingActive:false,
          configProfile:{activeConfigProfileUuid:$profile, activeInbounds:$inbounds}}')

    rw_api POST /api/nodes "$payload" || die "node registration request failed"
    rw_ok || die "panel rejected the node: $(rw_error)"

    local uuid
    uuid=$(printf '%s' "$RW_BODY" | jq -r '.response.uuid // empty')
    REGISTERED_UUID="$uuid"
    ok "registered as $NODE_NAME ($uuid)"
}

install_warp() {
    if [[ "${SKIP_WARP,,}" == "yes" ]]; then
        step "WARP"; info "skipped (SKIP_WARP=yes)"; return 0
    fi
    step "Cloudflare WARP (warp-native)"
    if systemctl is-active --quiet wg-quick@warp 2>/dev/null; then
        ok "already active"
        return 0
    fi
    # The installer asks three questions: language, WARP+ licence, watchdog
    # interval. Empty answers take the defaults (English / free / 10 min).
    curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh -o /tmp/warp-install.sh
    printf '1\n\n\n' | bash /tmp/warp-install.sh || warn "warp installer returned non-zero — check manually with: warp"
    rm -f /tmp/warp-install.sh
    if systemctl is-active --quiet wg-quick@warp 2>/dev/null; then
        ok "warp tunnel up"
    else
        warn "warp tunnel is not active — run 'warp' to inspect"
    fi
}

install_beszel() {
    step "Beszel agent"
    curl -sL https://get.beszel.dev -o /tmp/install-beszel.sh
    chmod +x /tmp/install-beszel.sh
    /tmp/install-beszel.sh \
        -k "$BESZEL_KEY" \
        -p "$BESZEL_PORT" \
        -t "$BESZEL_TOKEN" \
        -url "$BESZEL_HUB_URL" \
        || die "beszel agent install failed"
    rm -f /tmp/install-beszel.sh
    sleep 3
    if systemctl is-active --quiet beszel-agent 2>/dev/null; then
        ok "agent running — it should now appear on the hub automatically"
    else
        warn "beszel-agent is not active — check: journalctl -u beszel-agent -n 50"
    fi
}

migrate_ssh() {
    if [[ "${SKIP_SSH_PORT,,}" == "yes" ]]; then
        step "SSH port"; info "skipped (SKIP_SSH_PORT=yes)"; return 0
    fi
    step "Migrating SSH to port $SSH_PORT"

    if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then
        ok "already listening on $SSH_PORT"
        ufw delete allow 22/tcp >/dev/null 2>&1 || true
        SSH_MIGRATED=yes
        return 0
    fi

    # socket activation ignores the Port directive; move to the plain service.
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    fi
    systemctl enable --now ssh.service >/dev/null 2>&1 \
        || systemctl enable --now sshd.service >/dev/null 2>&1 || true

    # A drop-in beats sed'ing sshd_config: distro cloud-init drop-ins are read
    # after the main file and would otherwise win.
    mkdir -p /etc/ssh/sshd_config.d
    printf '# Managed by install-node.sh\nPort %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/99-remnanode-port.conf
    if grep -rqE '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i -E 's/^(\s*Port\s+.*)$/# \1  # superseded by sshd_config.d\/99-remnanode-port.conf/' /etc/ssh/sshd_config
    fi

    if ! sshd -t 2>/dev/null; then
        rm -f /etc/ssh/sshd_config.d/99-remnanode-port.conf
        warn "sshd config validation failed — reverted, SSH left on port 22"
        return 0
    fi

    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true

    local waited=0 listening=no
    while (( waited < 15 )); do
        if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then listening=yes; break; fi
        sleep 1; waited=$((waited + 1))
    done

    if [[ "$listening" == "yes" ]]; then
        ufw delete allow 22/tcp >/dev/null 2>&1 || true
        SSH_MIGRATED=yes
        ok "sshd listening on $SSH_PORT — port 22 closed"
        warn "your current session stays alive; new logins must use: ssh -p $SSH_PORT root@$NODE_DOMAIN"
    else
        rm -f /etc/ssh/sshd_config.d/99-remnanode-port.conf
        systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
        warn "nothing came up on $SSH_PORT — rolled back, port 22 left open"
    fi
}

summary() {
    step "Done"
    cat <<SUMMARY

     ${C_GRN}Node provisioned.${C_RESET}

       Panel node    ${NODE_NAME}  ->  ${NODE_DOMAIN}:${NODE_PORT}${REGISTERED_UUID:+  (${REGISTERED_UUID})}
       Selfsteal     https://${NODE_DOMAIN}  (Caddy on :${SELFSTEAL_PORT})
       TLS cert      ${CERT_PATH:-none mounted}
       SSH           $([[ "${SSH_MIGRATED:-no}" == "yes" ]] && echo "port ${SSH_PORT}" || echo "port 22 (unchanged)")
       Beszel        $(hostname) -> ${BESZEL_HUB_URL}
       IPv6          $([[ "$DISABLE_IPV6" == "yes" ]] && echo disabled || echo enabled)
       Congestion    $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)
       Log           ${LOG_FILE}

     ${C_YEL}Two things this script cannot do for you:${C_RESET}
       1. The A record for ${NODE_DOMAIN} must be DNS-only (grey cloud). If it is
          proxied through Cloudflare the panel cannot reach port ${NODE_PORT}.
       2. In the panel, your Reality inbound's serverNames must include
          ${NODE_DOMAIN} and its dest must point at 127.0.0.1:${SELFSTEAL_PORT},
          otherwise the selfsteal site is never actually used.

     Useful commands:
       docker logs -f remnanode
       ufw status numbered
       warp
       systemctl status beszel-agent

SUMMARY
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
    printf '%s\n' "=== install-node.sh $(date -Is) ===" >> "$LOG_FILE"

    preflight
    gather_input
    validate_panel
    resolve_config_profile
    beszel_login
    install_docker
    tune_kernel
    configure_ufw
    install_selfsteal
    locate_certs
    install_remnanode
    install_cert_watcher
    register_node
    install_warp
    install_beszel
    migrate_ssh
    summary
}

main "$@"
