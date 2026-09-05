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
# Any prompt can be pre-answered as a key=value argument or an environment
# variable; whatever you leave out is still asked for interactively:
#
#   bash <(curl -Ls .../install-node.sh) rpanelurl=https://panel.example.com \
#       sub=de1 name=DE-1 rtoken=xxxxx
#
# Run with --help for the full list of keys.
#
# Optional steps (DNS, selfsteal, beszel, WARP, SSH port) report a failure and
# carry on; only the panel token and the node container itself are fatal.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# CONFIG — edit these two once, then the script only ever asks for per-node data
# ---------------------------------------------------------------------------

PANEL_URL="${PANEL_URL:-}"              # e.g. https://panel.example.com  (no trailing slash)
BESZEL_HUB_URL="${BESZEL_HUB_URL:-}"    # e.g. https://beszel.example.com (no trailing slash)

# reg.ru DNS. Set the zone and login here; then each run only asks for a subdomain.
# The domain must use ns1.reg.ru / ns2.reg.ru, and API access must be enabled at
# https://www.reg.ru/user/account/#/settings/api/ with this server's IP allowed.
REGRU_ZONE="${REGRU_ZONE:-}"            # base domain, e.g. example.com
REGRU_USER="${REGRU_USER:-}"            # reg.ru account login
REGRU_PASSWORD="${REGRU_PASSWORD:-}"    # reg.ru API password (set a separate one, not your account password)

# Ports. These match the ufw rules opened below.
NODE_PORT="${NODE_PORT:-2222}"          # panel -> node internal API
SSH_PORT="${SSH_PORT:-2224}"            # new SSH port
SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"   # HTTPS, the Reality `target`
FALLBACK_PORT="${FALLBACK_PORT:-8080}"     # plaintext HTTP, the VLESS/TLS `fallbacks.dest`
BESZEL_PORT="${BESZEL_PORT:-45876}"

# Optional knobs
PANEL_EXTRA_HEADER="${PANEL_EXTRA_HEADER:-}"   # e.g. "X-Api-Key: secret" if the panel sits behind header auth
PANEL_IP="${PANEL_IP:-}"                       # override the auto-resolved panel IP for the NODE_PORT rule
CONFIG_PROFILE_UUID="${CONFIG_PROFILE_UUID:-}" # skip the config-profile picker
COUNTRY_CODE="${COUNTRY_CODE:-}"               # auto-detected if empty
DISABLE_IPV6="${DISABLE_IPV6:-}"               # yes | no  (prompted if empty)
MANAGE_DNS="${MANAGE_DNS:-}"                   # yes | no  (prompted if empty)
NODE_SUBDOMAIN="${NODE_SUBDOMAIN:-}"           # label only, e.g. "de1", or "@" for the zone apex
DNS_WAIT_SECONDS="${DNS_WAIT_SECONDS:-300}"    # how long to wait for the record to propagate
BESZEL_PERMANENT_TOKEN="${BESZEL_PERMANENT_TOKEN:-no}"  # yes = persist the universal token on the hub
SKIP_WARP="${SKIP_WARP:-no}"
# Reuse WARP credentials from a machine where registration already worked.
# Each accepts a local path, an http(s) URL, or the file's base64.
WARP_ACCOUNT="${WARP_ACCOUNT:-}"   # wgcf-account.toml  — skips registration
WARP_PROFILE="${WARP_PROFILE:-}"   # wgcf-profile.conf  — skips registration AND generate
SKIP_SSH_PORT="${SKIP_SSH_PORT:-no}"

# --- Torrent guard / speed shaper ------------------------------------------
# Both run as part of a full install. They confine themselves to their own
# nftables tables, so they neither fight ufw nor the Remnawave node plugin.
SKIP_TORRENT_GUARD="${SKIP_TORRENT_GUARD:-no}"
SKIP_SHAPER="${SKIP_SHAPER:-no}"        # set yes on CDN-fronted nodes

# Ports xray exposes to clients. Everything else on the wire — panel, beszel,
# ssh — is deliberately not measured. configure_ufw opens exactly these.
SHAPE_PORTS="${SHAPE_PORTS:-443}"
SHAPE_TRIGGER_MBIT="${SHAPE_TRIGGER_MBIT:-100}"  # sustained rate that trips it
SHAPE_TRIGGER_SECONDS="${SHAPE_TRIGGER_SECONDS:-120}"
SHAPE_CAP_MBIT="${SHAPE_CAP_MBIT:-8}"            # what an offender is held to
SHAPE_RELEASE_MBIT="${SHAPE_RELEASE_MBIT:-4}"    # "gone quiet" threshold
SHAPE_RELEASE_SECONDS="${SHAPE_RELEASE_SECONDS:-300}"
SHAPE_UPLOAD="${SHAPE_UPLOAD:-yes}"              # no = shape download only
SHAPE_MAX_CLIENTS="${SHAPE_MAX_CLIENTS:-64}"
SHAPE_MAX_CONNS="${SHAPE_MAX_CONNS:-200}"        # above this, assume CDN/CGNAT
SHAPE_IGNORE_IPS="${SHAPE_IGNORE_IPS:-}"         # space or comma separated
RUN_MODE="${RUN_MODE:-}"        # menu | all; empty = menu when there are no arguments

# Prompted for if still empty. Declared here so `set -u` never trips on a path
# that skips the prompt, and so the plain env-var names work as overrides.
NODE_DOMAIN="${NODE_DOMAIN:-}"
NODE_NAME="${NODE_NAME:-}"
REMNA_TOKEN="${REMNA_TOKEN:-}"
BESZEL_EMAIL="${BESZEL_EMAIL:-}"
BESZEL_PASSWORD="${BESZEL_PASSWORD:-}"

ZAPRET_DIR="${ZAPRET_DIR:-/opt/zapret}"
DPI_LOG_DIR=/var/log/dpi-detector

INSTALL_DIR="/opt/remnanode"
XRAY_SSL_DIR="/var/lib/remnawave/configs/xray/ssl"
LOG_FILE="/var/log/remnanode-autoinstall.log"
GUARD_NFT="/etc/rw-torrent-guard.nft"
SHAPER_BIN="/usr/local/bin/rw-shaper"
SHAPER_CONF="/etc/rw-shaper.conf"

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
CURRENT_STEP=""
FAILED_STEPS=()

step() {
    STEP_NO=$((STEP_NO + 1)); CURRENT_STEP="$*"
    printf '\n%s==> [%02d] %s%s\n' "$C_BLU" "$STEP_NO" "$*" "$C_RESET"
}
info() { printf '     %s\n' "$*"; }
ok()   { printf '     %s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '     %s!%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# Failure inside an OPTIONAL step. Records it for the closing summary and
# returns 0, so the caller writes `... || { soft_fail "why"; return 1; }` and the
# run carries on. Anything that would leave a broken node still uses die().
soft_fail() {
    printf '     %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
    FAILED_STEPS+=("${CURRENT_STEP} — $*")
    return 0
}

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
# Arguments: key=value pairs, in any order. Anything you leave out is prompted
# for exactly as before, so you can fill in as much or as little as you like.
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: install-node.sh [key=value ...]

  Every setting can be given as key=value; whatever you omit is prompted for.

  Panel      rpanelurl=   https://panel.example.com
             rtoken=      Remnawave API token
             profile=     config profile UUID        panelip=  override panel IP
  Node       name=        node name (3-30 chars)     nodeport= default 2222
             domain=      full hostname (when dns=no)
  DNS        dns=         yes|no                     zone=     example.com
             sub=         subdomain label, or @      reguser=  reg.ru login
             regpass=     reg.ru API password
  Beszel     beszelurl=   https://beszel.example.com
             buser=       hub email (aka bemail=, beszeluser=, blogin=)
             bpass=       hub password (aka bpassword=, bpwd=)
             bkey=        hub public key             btoken=   universal token
                          (bkey + btoken skip the hub login entirely)
  System     ipv6=        keep|disable               sshport=  default 2224
             skipwarp=    yes|no                     skipssh=  yes|no
  Guard      skipguard=   yes|no   skip the nftables torrent guard
             skipshaper=  yes|no   skip the speed shaper (set on CDN nodes)
             shapeports=  client-facing ports to meter        default 443
             shapetrigger=Mbit/s that trips it                default 100
             shapefor=    seconds it must be sustained        default 120
             shapecap=    Mbit/s an offender is held to       default 8
             shapeupload= yes|no   also shape the upload direction
             shapeignore= addresses never to shape (comma separated)
  WARP       warpprofile= reuse a wgcf-profile.conf (path, URL or base64)
                          — needs no Cloudflare access at all
             warpaccount= reuse a wgcf-account.toml; skips registration, but
                          `wgcf generate` still calls the Cloudflare API

  With no arguments you get an interactive menu of individual steps.
  Pass `all` to force the full unattended install instead.

  Example:
    install-node.sh rpanelurl=https://panel.example.com sub=de1 name=DE-1

  Note: values passed this way are visible to other users via `ps` and land in
  your shell history. For secrets, prefer letting the script prompt you.
USAGE
}

set_var() { printf -v "$1" '%s' "$2"; }

parse_args() {
    local arg key val
    for arg in "$@"; do
        case "$arg" in
            -h|--help|help)     usage; exit 0 ;;
            all|full|install)   RUN_MODE=all;  continue ;;
            menu)               RUN_MODE=menu; continue ;;
        esac
        if [[ "$arg" != *=* ]]; then
            warn "ignoring argument (expected key=value): $arg"
            continue
        fi
        key="${arg%%=*}"; val="${arg#*=}"
        key="${key#--}"
        # Fold case and drop separators, so RPANELURL, rpanel-url and
        # PANEL_URL all land on the same setting.
        key="$(printf '%s' "$key" | tr -d '_-' | tr '[:upper:]' '[:lower:]')"
        case "$key" in
            panelurl|rpanelurl|panel|remnaurl)          set_var PANEL_URL "$val" ;;
            remnatoken|rtoken|token|apikey|panelkey)    set_var REMNA_TOKEN "$val" ;;
            panelip)                                    set_var PANEL_IP "$val" ;;
            panelextraheader|extraheader)               set_var PANEL_EXTRA_HEADER "$val" ;;
            configprofileuuid|profile)                  set_var CONFIG_PROFILE_UUID "$val" ;;
            nodename|name)                              set_var NODE_NAME "$val" ;;
            nodedomain|domain|fqdn|host)                set_var NODE_DOMAIN "$val" ;;
            nodesubdomain|subdomain|sub)                set_var NODE_SUBDOMAIN "$val" ;;
            nodeport)                                   set_var NODE_PORT "$val" ;;
            countrycode|country|cc)                     set_var COUNTRY_CODE "$val" ;;
            managedns|dns)                              set_var MANAGE_DNS "$val" ;;
            regruzone|zone)                             set_var REGRU_ZONE "$val" ;;
            regruuser|reguser|regrulogin)               set_var REGRU_USER "$val" ;;
            regrupassword|regrupass|regpass)            set_var REGRU_PASSWORD "$val" ;;
            dnswaitseconds|dnswait)                     set_var DNS_WAIT_SECONDS "$val" ;;
            beszelhuburl|beszelurl|huburl|bhub)         set_var BESZEL_HUB_URL "$val" ;;
            beszelemail|beszeluser|beszelusername|beszellogin|bemail|buser|busername|blogin)
                                                        set_var BESZEL_EMAIL "$val" ;;
            beszelpassword|beszelpass|bpassword|bpass|bpwd)
                                                        set_var BESZEL_PASSWORD "$val" ;;
            beszelkey|bkey)                             set_var BESZEL_KEY "$val" ;;
            beszeltoken|btoken)                         set_var BESZEL_TOKEN "$val" ;;
            beszelpermanenttoken|btokenpermanent)       set_var BESZEL_PERMANENT_TOKEN "$val" ;;
            beszelport)                                 set_var BESZEL_PORT "$val" ;;
            disableipv6|ipv6disable|noipv6)             set_var DISABLE_IPV6 "$val" ;;
            ipv6)  # ipv6=keep / ipv6=disable reads better than a double negative
                case "${val,,}" in
                    disable|off|no|false) set_var DISABLE_IPV6 yes ;;
                    *)                    set_var DISABLE_IPV6 no  ;;
                esac ;;
            sshport)                                    set_var SSH_PORT "$val" ;;
            selfstealport)                              set_var SELFSTEAL_PORT "$val" ;;
            skipwarp|nowarp)                            set_var SKIP_WARP "$val" ;;
            warpaccount|wgcfaccount|warpacct)           set_var WARP_ACCOUNT "$val" ;;
            warpprofile|wgcfprofile|warpconf)           set_var WARP_PROFILE "$val" ;;
            skipsshport|skipssh)                        set_var SKIP_SSH_PORT "$val" ;;
            skiptorrentguard|skipguard|noguard)         set_var SKIP_TORRENT_GUARD "$val" ;;
            skipshaper|noshaper)                        set_var SKIP_SHAPER "$val" ;;
            shapeports)                                 set_var SHAPE_PORTS "$val" ;;
            shapetriggermbit|shapetrigger)              set_var SHAPE_TRIGGER_MBIT "$val" ;;
            shapetriggerseconds|shapefor)               set_var SHAPE_TRIGGER_SECONDS "$val" ;;
            shapecapmbit|shapecap)                      set_var SHAPE_CAP_MBIT "$val" ;;
            shapereleasembit|shaperelease)              set_var SHAPE_RELEASE_MBIT "$val" ;;
            shapereleaseseconds|shapereleasefor)        set_var SHAPE_RELEASE_SECONDS "$val" ;;
            shapeupload)                                set_var SHAPE_UPLOAD "$val" ;;
            shapemaxclients)                            set_var SHAPE_MAX_CLIENTS "$val" ;;
            shapemaxconns)                              set_var SHAPE_MAX_CONNS "$val" ;;
            shapeignoreips|shapeignore)                 set_var SHAPE_IGNORE_IPS "$val" ;;
            installdir)                                 set_var INSTALL_DIR "$val" ;;
            *) warn "unknown argument: ${arg%%=*}  (run with --help for the list)" ;;
        esac
    done
}

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

BESZEL_AUTH=""
BESZEL_KEY="${BESZEL_KEY:-}"
BESZEL_TOKEN="${BESZEL_TOKEN:-}"
BESZEL_IS_SUPERUSER=no
BZ_LAST_ERROR=""
BZ_MFA=""

bz_get() {  # bz_get <path>
    curl -sS --max-time 30 -H "Authorization: ${BESZEL_AUTH}" -H "Accept: application/json" \
        "${BESZEL_HUB_URL}$1"
}

# PocketBase keeps ordinary users and superusers in separate auth collections,
# and rejects a login against the wrong one with "the request doesn't satisfy
# the collection requirements to authenticate". Try both.
bz_auth_try() {  # bz_auth_try <collection>
    local coll=$1 payload resp
    payload=$(jq -nc --arg i "$BESZEL_EMAIL" --arg p "$BESZEL_PASSWORD" '{identity:$i, password:$p}')
    resp=$(curl -sS --max-time 30 -X POST -H "Content-Type: application/json" \
        --data-binary "$payload" \
        "${BESZEL_HUB_URL}/api/collections/${coll}/auth-with-password" 2>/dev/null || true)
    BZ_LAST_ERROR=$(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null || true)
    BESZEL_AUTH=$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null || true)
    # With MFA on, PocketBase answers a first-factor login with an mfaId and no
    # token, which is not something this script can complete unattended.
    BZ_MFA=$(printf '%s' "$resp" | jq -r '.mfaId // empty' 2>/dev/null || true)
    [[ -n "$BESZEL_AUTH" ]]
}

# ---------------------------------------------------------------------------
# reg.ru REG.API 2 — https://www.reg.ru/reseller/api2doc
#
# Everything is POSTed as input_format=json + input_data={...}, with the
# credentials inside the JSON body. Two layers of result reporting: a top-level
# .result for the call, and a per-domain .answer.domains[].result for the zone.
# ---------------------------------------------------------------------------

REGRU_BODY=""

regru_api() {  # regru_api <category/function> [extra JSON object]
    local path=$1 extra=${2:-'{}'} payload
    payload=$(jq -nc \
        --arg u "$REGRU_USER" --arg p "$REGRU_PASSWORD" --arg d "$REGRU_ZONE" \
        --argjson extra "$extra" \
        '{username:$u, password:$p, domains:[{dname:$d}], output_content_type:"plain"} + $extra')
    REGRU_BODY=$(curl -sS --max-time 45 \
        --data-urlencode "input_format=json" \
        --data-urlencode "input_data=${payload}" \
        "https://api.reg.ru/api/regru2/${path}") || return 1
}

regru_ok() { [[ "$(printf '%s' "$REGRU_BODY" | jq -r '.result // "error"' 2>/dev/null)" == "success" ]]; }

regru_err() {
    printf '%s' "$REGRU_BODY" \
        | jq -r '"\(.error_code // "UNKNOWN") — \(.error_text // "no detail")"' 2>/dev/null \
        || printf '%s' "$REGRU_BODY" | head -c 200
}

regru_zone_ok() {
    [[ "$(printf '%s' "$REGRU_BODY" | jq -r '.answer.domains[0].result // "error"' 2>/dev/null)" == "success" ]]
}

regru_zone_err() {
    printf '%s' "$REGRU_BODY" \
        | jq -r '.answer.domains[0] | "\(.error_code // .result // "unknown") — \(.error_text // "")"' 2>/dev/null
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
    # nftables is a hard requirement of the Remnawave node plugin as well as of
    # the torrent guard and the shaper's accounting.
    have nft  || need+=(nftables)
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

# --- Input gathering -------------------------------------------------------
# Split into small need_* helpers so a single menu action asks only for what it
# actually uses, instead of interrogating you about beszel to set up a firewall.
# Each is idempotent: safe to call from several actions in one session.

_HAVE_PANEL=no
_HAVE_DOMAIN=no
_HAVE_NAME=no
_HAVE_BESZEL=no
_HAVE_IPV6=no

# Pull the SECRET_KEY back out of a compose file written by an earlier run.
node_secret_from_compose() {
    local f="$INSTALL_DIR/docker-compose.yml" v
    [[ -f "$f" ]] || return 1
    v=$(sed -n 's/^[[:space:]]*-[[:space:]]*SECRET_KEY=//p' "$f" | head -1)
    v="${v%\"}"; v="${v#\"}"
    [[ -n "$v" ]] || return 1
    printf '%s' "$v"
}

# Recover the node's domain from what is already installed, so a re-run does not
# have to ask. Tries the cert mount in the compose file, then selfsteal's env.
detect_node_domain() {
    local d="" f
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        d=$(sed -n 's#.*/certificates/[^/]*/\([^/]*\)/\1\.crt.*#\1#p' \
            "$INSTALL_DIR/docker-compose.yml" | head -1)
    fi
    if [[ -z "$d" ]]; then
        for f in /opt/caddy/.env /opt/nginx-selfsteal/.env; do
            [[ -f "$f" ]] || continue
            d=$(sed -n 's/^SELF_STEAL_DOMAIN=//p' "$f" | tr -d '"' | head -1)
            [[ -n "$d" ]] && break
        done
    fi
    printf '%s' "$d"
}

need_panel() {
    [[ "$_HAVE_PANEL" == "yes" ]] && return 0
    ask PANEL_URL "Remnawave panel URL (https://panel.example.com)"
    PANEL_URL="$(strip_slash "$PANEL_URL")"
    ask_secret REMNA_TOKEN "Remnawave API token"

    step "Validating Remnawave API token"
    rw_api GET /api/nodes || die "cannot reach $PANEL_URL"
    rw_ok || die "panel rejected the token: $(rw_error)"
    local count
    count=$(printf '%s' "$RW_BODY" | jq -r '.response | length' 2>/dev/null || echo 0)
    ok "token valid — panel currently has $count node(s)"

    if [[ -z "$PANEL_IP" ]]; then
        local panel_host="${PANEL_URL#*://}"; panel_host="${panel_host%%/*}"; panel_host="${panel_host%%:*}"
        PANEL_IP="$(dig +short A "$panel_host" | grep -E '^[0-9.]+$' | head -1 || true)"
    fi
    [[ -n "$PANEL_IP" ]] && ok "panel IP: $PANEL_IP" \
        || warn "could not resolve panel IP — port $NODE_PORT will be opened to all sources"
    _HAVE_PANEL=yes
}

need_domain() {
    [[ "$_HAVE_DOMAIN" == "yes" ]] && return 0
    if [[ -z "$NODE_DOMAIN" ]]; then
        local detected=""
        [[ "$MANAGE_DNS" != "yes" ]] && detected="$(detect_node_domain)"
        if [[ -n "$detected" ]]; then
            MANAGE_DNS="${MANAGE_DNS:-no}"
            ask NODE_DOMAIN "Node domain" "$detected"
            ok "node domain: $NODE_DOMAIN"
            _HAVE_DOMAIN=yes
            return 0
        fi
        ask_yes_no MANAGE_DNS "Manage the DNS A record via reg.ru?" "yes"
        if [[ "$MANAGE_DNS" == "yes" ]]; then
            ask REGRU_ZONE "reg.ru zone (base domain, e.g. example.com)"
            ask NODE_SUBDOMAIN "Subdomain label (e.g. de1, or @ for the zone itself)"
            NODE_SUBDOMAIN="${NODE_SUBDOMAIN%.}"
            NODE_SUBDOMAIN="${NODE_SUBDOMAIN%".$REGRU_ZONE"}"   # tolerate a pasted hostname
            if [[ "$NODE_SUBDOMAIN" == "@" || "$NODE_SUBDOMAIN" == "$REGRU_ZONE" ]]; then
                NODE_SUBDOMAIN="@"; NODE_DOMAIN="$REGRU_ZONE"
            else
                NODE_DOMAIN="${NODE_SUBDOMAIN}.${REGRU_ZONE}"
            fi
        else
            ask NODE_DOMAIN "Node domain (full hostname)"
        fi
    elif [[ -z "$MANAGE_DNS" ]]; then
        MANAGE_DNS=no
    fi
    ok "node domain: $NODE_DOMAIN"
    _HAVE_DOMAIN=yes
}

need_regru() {
    need_domain
    [[ "$MANAGE_DNS" == "yes" ]] || return 0
    ask REGRU_USER "reg.ru account login"
    ask_secret REGRU_PASSWORD "reg.ru API password"
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        die "cannot create a DNS record without a detected public IPv4"
    fi
    return 0
}

need_node_name() {
    [[ "$_HAVE_NAME" == "yes" ]] && return 0
    ask NODE_NAME "Node name (panel + beszel)"
    [[ ${#NODE_NAME} -ge 3 && ${#NODE_NAME} -le 30 ]] \
        || die "node name must be 3-30 characters (panel constraint)"
    _HAVE_NAME=yes
}

need_beszel() {
    [[ "$_HAVE_BESZEL" == "yes" ]] && return 0
    ask BESZEL_HUB_URL "Beszel hub URL (https://beszel.example.com)"
    BESZEL_HUB_URL="$(strip_slash "$BESZEL_HUB_URL")"
    if [[ -n "$BESZEL_KEY" && -n "$BESZEL_TOKEN" ]]; then
        info "beszel key and token supplied — no hub login needed"
    else
        ask BESZEL_EMAIL "Beszel hub email (an ordinary user, NOT a superuser)"
        ask_secret BESZEL_PASSWORD "Beszel hub password"
    fi
    _HAVE_BESZEL=yes
}

need_ipv6() {
    [[ "$_HAVE_IPV6" == "yes" ]] && return 0
    ask_yes_no DISABLE_IPV6 "Disable IPv6 on this server?" "no"
    _HAVE_IPV6=yes
}

need_country() {
    if [[ -z "$COUNTRY_CODE" ]]; then
        COUNTRY_CODE="$(curl -sS --max-time 8 "https://ipapi.co/${PUBLIC_IP:-}/country" 2>/dev/null | tr -dc 'A-Za-z' | head -c 2 || true)"
    fi
    [[ ${#COUNTRY_CODE} -eq 2 ]] || COUNTRY_CODE="XX"
    COUNTRY_CODE="${COUNTRY_CODE^^}"
    info "country code: $COUNTRY_CODE"
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
    step "Beszel hub"

    if [[ -n "$BESZEL_KEY" && -n "$BESZEL_TOKEN" ]]; then
        ok "key and token supplied directly — skipping the hub login"
        return 0
    fi
    if [[ -z "$BESZEL_EMAIL" || -z "$BESZEL_PASSWORD" ]]; then
        soft_fail "no hub credentials given — beszel will be skipped"
        return 1
    fi

    if bz_auth_try users; then
        ok "logged in to the 'users' collection as $BESZEL_EMAIL"
    elif bz_auth_try _superusers; then
        BESZEL_IS_SUPERUSER=yes
        ok "logged in as a superuser"
        warn "the hub refuses universal tokens to superusers, by design"
        warn "for hands-off enrolment, make an ordinary user at ${BESZEL_HUB_URL}/_/#/collections?collection=users"
    elif [[ -n "${BZ_MFA:-}" ]]; then
        soft_fail "beszel requires a second factor (MFA) — cannot log in unattended"
        warn "read the key and universal token off the hub yourself and pass them:"
        warn "  bkey='ssh-ed25519 ...' btoken=<uuid>"
        return 1
    else
        soft_fail "beszel login failed: ${BZ_LAST_ERROR:-no token returned}"
        warn "tried both the 'users' and '_superusers' collections. That message from"
        warn "PocketBase has three usual causes, in order of likelihood:"
        warn "  1. the hub runs with DISABLE_PASSWORD_AUTH=true (OIDC-only login)"
        warn "  2. you gave a username — the identity field is the EMAIL address"
        warn "  3. no such account: create an ordinary user (not a superuser) at"
        warn "     ${BESZEL_HUB_URL}/_/#/collections?collection=users"
        warn "either way you can skip the login entirely by passing the values:"
        warn "  bkey='ssh-ed25519 ...' btoken=<uuid>"
        warn "both are on the hub under Settings -> Tokens / Add system."
        return 1
    fi

    BESZEL_KEY=$(bz_get /api/beszel/getkey | jq -r '.key // empty' 2>/dev/null || true)
    if [[ -z "$BESZEL_KEY" ]]; then
        soft_fail "could not read the hub public key from /api/beszel/getkey"
        return 1
    fi
    ok "hub public key retrieved"

    if [[ "$BESZEL_IS_SUPERUSER" == "yes" ]]; then
        warn "no universal token — the agent installs, but you must add this system"
        warn "on the hub manually (host ${NODE_DOMAIN}, port ${BESZEL_PORT})"
        return 0
    fi

    local tok_resp
    tok_resp=$(bz_get /api/beszel/universal-token 2>/dev/null || true)
    if [[ "$(printf '%s' "$tok_resp" | jq -r '.active // false' 2>/dev/null)" == "true" ]]; then
        BESZEL_TOKEN=$(printf '%s' "$tok_resp" | jq -r '.token')
        info "reusing the universal token already active on the hub"
    else
        local q="/api/beszel/universal-token?enable=1"
        [[ "${BESZEL_PERMANENT_TOKEN,,}" == "yes" ]] && q+="&permanent=1"
        tok_resp=$(bz_get "$q" 2>/dev/null || true)
        BESZEL_TOKEN=$(printf '%s' "$tok_resp" | jq -r '.token // empty' 2>/dev/null || true)
        if [[ -z "$BESZEL_TOKEN" ]]; then
            warn "could not obtain a universal token — the agent will still be installed,"
            warn "but you must add this system on the hub manually"
            return 0
        fi
        if [[ "$(printf '%s' "$tok_resp" | jq -r '.permanent // false')" == "true" ]]; then
            info "enabled a permanent universal token on the hub"
        else
            info "enabled a 1-hour ephemeral universal token"
        fi
    fi
    ok "universal token ready"
}

setup_dns() {
    if [[ "$MANAGE_DNS" != "yes" ]]; then
        step "DNS"; info "skipped — managing the record yourself"; return 0
    fi
    step "DNS record via reg.ru"

    regru_api nop || { soft_fail "cannot reach api.reg.ru"; return 1; }
    if ! regru_ok; then
        local code
        code=$(printf '%s' "$REGRU_BODY" | jq -r '.error_code // "UNKNOWN"')
        # reg.ru checks the IP allowlist before it checks the password, so this
        # is the first thing a brand-new server hits.
        if [[ "$code" == "ACCESS_DENIED_FROM_IP" ]]; then
            soft_fail "reg.ru refused this server's IP ($PUBLIC_IP)"
            warn "add it (or allow all addresses) at"
            warn "  https://www.reg.ru/user/account/#/settings/api/"
            warn "then re-run. Continuing without DNS: the record will not exist,"
            warn "so ACME will fail and selfsteal falls back to a self-signed cert."
        else
            soft_fail "reg.ru rejected the request: $(regru_err)"
        fi
        return 1
    fi
    ok "authenticated as $REGRU_USER"

    # Zone management only works when the domain actually uses reg.ru nameservers.
    regru_api zone/nop || { soft_fail "zone/nop request failed"; return 1; }
    if ! regru_zone_ok; then
        soft_fail "cannot manage the DNS zone for $REGRU_ZONE: $(regru_zone_err)"
        warn "the domain must use ns1.reg.ru and ns2.reg.ru"
        return 1
    fi
    ok "zone $REGRU_ZONE is manageable"

    regru_api zone/get_resource_records || { soft_fail "cannot read the zone records"; return 1; }
    regru_zone_ok || { soft_fail "cannot read the zone records: $(regru_zone_err)"; return 1; }

    local existing
    existing=$(printf '%s' "$REGRU_BODY" | jq -r --arg s "$NODE_SUBDOMAIN" \
        '[.answer.domains[0].rrs[]? | select(.rectype == "A" and .subname == $s) | .content] | join(" ")')

    if [[ "$existing" == "$PUBLIC_IP" ]]; then
        ok "$NODE_DOMAIN already points at $PUBLIC_IP — nothing to do"
        return 0
    fi

    if [[ -n "$existing" ]]; then
        warn "$NODE_DOMAIN currently points at: $existing"
        local old
        for old in $existing; do
            regru_api zone/remove_record "$(jq -nc --arg s "$NODE_SUBDOMAIN" --arg c "$old" \
                '{subdomain:$s, record_type:"A", content:$c}')" \
                || { soft_fail "remove_record request failed"; return 1; }
            regru_zone_ok || { soft_fail "could not remove the stale A record $old: $(regru_zone_err)"; return 1; }
            info "removed stale A record $old"
        done
    fi

    regru_api zone/add_alias "$(jq -nc --arg s "$NODE_SUBDOMAIN" --arg ip "$PUBLIC_IP" \
        '{subdomain:$s, ipaddr:$ip}')" || { soft_fail "add_alias request failed"; return 1; }
    regru_zone_ok || { soft_fail "could not create the A record: $(regru_zone_err)"; return 1; }
    ok "A record $NODE_DOMAIN -> $PUBLIC_IP created"
}

await_dns() {
    step "Waiting for DNS"
    local waited=0 resolved=""
    while (( waited < DNS_WAIT_SECONDS )); do
        # Ask a public resolver directly; the local one may still hold a negative cache entry.
        resolved="$(dig +short A "$NODE_DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
        [[ -n "$resolved" && ( -z "$PUBLIC_IP" || "$resolved" == "$PUBLIC_IP" ) ]] && break
        sleep 10; waited=$((waited + 10))
        (( waited % 60 == 0 )) && info "still waiting... ${waited}s (currently: ${resolved:-NXDOMAIN})"
    done

    if [[ -z "$resolved" ]]; then
        warn "$NODE_DOMAIN still does not resolve after ${waited}s — ACME will fail"
        warn "selfsteal will fall back to a self-signed certificate"
    elif [[ -n "$PUBLIC_IP" && "$resolved" != "$PUBLIC_IP" ]]; then
        warn "$NODE_DOMAIN resolves to $resolved but this host is $PUBLIC_IP"
        warn "if that is a Cloudflare proxy IP, switch the record to DNS-only or the panel cannot reach port $NODE_PORT"
    else
        ok "$NODE_DOMAIN -> $resolved"
    fi
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
    if ! bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install \
            --force --domain "$NODE_DOMAIN" --port "$SELFSTEAL_PORT"; then
        soft_fail "selfsteal install failed"
        warn "no masquerade site and no ACME certificate; the node still comes up"
        return 1
    fi
    ok "installed on port $SELFSTEAL_PORT for $NODE_DOMAIN"
}

# A VLESS-TCP-TLS inbound terminates TLS in Xray and hands the *decrypted* bytes
# to fallbacks.dest, so that destination must speak plaintext HTTP. Selfsteal's
# :9443 is HTTPS (Reality needs it for raw passthrough) and :80 only issues a
# redirect, which would loop. Hence a third listener serving the same site in
# the clear, on loopback only.
configure_fallback_site() {
    step "Plaintext fallback site (VLESS-TCP-TLS)"

    local cname caddyfile=""
    for cname in $(docker ps --format '{{.Names}}' | grep -i caddy || true); do
        caddyfile=$(docker inspect -f \
            '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' \
            "$cname" 2>/dev/null || true)
        [[ -n "$caddyfile" ]] && break
    done
    if [[ -z "$caddyfile" || ! -f "$caddyfile" ]]; then
        soft_fail "could not find the selfsteal Caddyfile — skipping the fallback site"
        return 1
    fi

    if grep -q 'remnanode-fallback' "$caddyfile"; then
        ok "already present on :${FALLBACK_PORT}"
        return 0
    fi

    cp -a "$caddyfile" "${caddyfile}.remnanode.bak"
    cat >> "$caddyfile" <<EOF

# remnanode-fallback — added by install-node.sh
# Plaintext HTTP for VLESS-TCP-TLS fallbacks.dest. Xray terminates TLS itself,
# so this listener must NOT speak TLS. Loopback only; never expose it.
:${FALLBACK_PORT} {
	bind 127.0.0.1
	encode gzip
	header {
		-Server
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		X-XSS-Protection "1; mode=block"
	}
	root * /var/www/html
	try_files {path} /index.html
	file_server
}
EOF

    if ! docker exec "$cname" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        mv -f "${caddyfile}.remnanode.bak" "$caddyfile"
        soft_fail "Caddy rejected the fallback site — reverted, selfsteal untouched"
        return 1
    fi

    docker restart "$cname" >/dev/null 2>&1 || true
    local waited=0
    while (( waited < 30 )); do
        if curl -sf --max-time 3 -o /dev/null "http://127.0.0.1:${FALLBACK_PORT}/"; then
            ok "serving plaintext HTTP on 127.0.0.1:${FALLBACK_PORT}"
            rm -f "${caddyfile}.remnanode.bak"
            return 0
        fi
        sleep 2; waited=$((waited + 2))
    done
    soft_fail "nothing answering on 127.0.0.1:${FALLBACK_PORT} — check: docker logs $cname"
    return 1
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
    local secret=""

    # Only the panel can mint this key, but it is already sitting in the compose
    # file on a node that has been set up before. Reuse it, so actions that just
    # rewrite the compose (linking certificates, say) need no panel access at
    # all. If the panel has already been validated this run, take a fresh key —
    # that is the case where you might be pointing the node at a new panel.
    if [[ "$_HAVE_PANEL" != "yes" ]] && secret=$(node_secret_from_compose); then
        ok "reusing the SECRET_KEY already in $INSTALL_DIR/docker-compose.yml"
    else
        need_panel
        rw_api GET /api/keygen || die "cannot reach /api/keygen"
        rw_ok || die "cannot fetch the node key: $(rw_error)"

        # Panel 2.8.x and older return this as .response.pubKey; newer panels
        # renamed the field to .response.secretKey. The value is byte-identical
        # either way — a base64 payload of nodeCertPem/nodeKeyPem/caCertPem/
        # jwtPublicKey — and the node always reads it from SECRET_KEY.
        secret=$(printf '%s' "$RW_BODY" | jq -r '.response.secretKey // .response.pubKey // empty')
        if [[ -z "$secret" ]]; then
            die "/api/keygen returned neither secretKey nor pubKey
     fields present: $(printf '%s' "$RW_BODY" | jq -rc '.response | keys' 2>/dev/null || echo 'unparseable')"
        fi
        if printf '%s' "$secret" | base64 -d 2>/dev/null | jq -e '.jwtPublicKey' >/dev/null 2>&1; then
            ok "node key retrieved and payload verified"
        else
            ok "node key retrieved"
            warn "payload did not decode to the expected shape — the node may reject it"
        fi
    fi

    mkdir -p "$INSTALL_DIR" /var/log/remnanode

    {
        echo "services:"
        echo "  remnanode:"
        echo "    container_name: remnanode"
        echo "    hostname: remnanode"
        echo "    image: remnawave/node:latest"
        echo "    restart: always"
        echo "    network_mode: host"
        # Present in the upstream docker-compose-prod.yml; xray needs it for
        # routing/tproxy features.
        echo "    cap_add:"
        echo "      - NET_ADMIN"
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
    need_country

    if rw_api GET /api/nodes && rw_ok; then
        EXISTING_NODE_UUID="$(printf '%s' "$RW_BODY" \
            | jq -r --arg n "$NODE_NAME" --arg a "$NODE_DOMAIN" \
              '.response[] | select(.name == $n or .address == $a) | .uuid' 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "${EXISTING_NODE_UUID:-}" ]]; then
        warn "a node named '$NODE_NAME' or addressed '$NODE_DOMAIN' already exists"
        warn "skipping registration — $EXISTING_NODE_UUID left untouched"
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

# Accept a local path, an http(s) URL, or raw base64, and land it at $2.
# $3 is a regex the result must match, so a 404 page or a bad paste is caught
# here rather than surfacing later as a confusing wireguard error.
materialise_file() {  # materialise_file <source> <dest> <sanity regex>
    local src=$1 dest=$2 needle=$3
    if [[ -f "$src" ]]; then
        cp -f "$src" "$dest" || return 1
    elif [[ "$src" == http://* || "$src" == https://* ]]; then
        curl -fsSL --max-time 30 "$src" -o "$dest" || return 1
    else
        printf '%s' "$src" | base64 -d > "$dest" 2>/dev/null || return 1
    fi
    if ! grep -qE "$needle" "$dest" 2>/dev/null; then
        rm -f "$dest"
        return 1
    fi
    chmod 600 "$dest"
    return 0
}

# Install straight from a wgcf-profile.conf, doing by hand what warp-native does
# after `wgcf generate`. This is the only path that needs no Cloudflare API call
# at all, so it is what works on a fully blocked network.
warp_install_from_profile() {
    local conf=/etc/wireguard/warp.conf
    if ! have wg-quick; then
        info "installing wireguard"
        apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools >/dev/null 2>&1 || {
            soft_fail "could not install wireguard"; return 1; }
    fi
    mkdir -p /etc/wireguard
    if ! materialise_file "$WARP_PROFILE" "$conf" '^\[Interface\]'; then
        soft_fail "supplied WARP profile is not a readable wgcf-profile.conf"
        return 1
    fi

    # Same edits warp-native applies to the generated profile.
    sed -i '/^DNS =/d' "$conf"
    grep -q 'Table = off' "$conf" || sed -i '/^MTU =/aTable = off' "$conf"
    grep -q 'PersistentKeepalive = 25' "$conf" || sed -i '/^Endpoint =/aPersistentKeepalive = 25' "$conf"
    sed -i 's/,[[:space:]]*[0-9a-fA-F:]\+\/128//' "$conf"
    sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "$conf"
    chmod 600 "$conf"

    if ! systemctl enable --now wg-quick@warp >/dev/null 2>&1; then
        soft_fail "wg-quick@warp failed to start — check: journalctl -u wg-quick@warp"
        return 1
    fi
    ok "warp up from the supplied profile"
    warn "this profile is one Cloudflare device; reusing it on several servers at"
    warn "once may get the device dropped. Register per-node when you can."
    return 0
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

    # A ready-made profile bypasses Cloudflare entirely.
    if [[ -n "$WARP_PROFILE" ]]; then
        info "using the supplied wgcf-profile.conf — no Cloudflare API needed"
        warp_install_from_profile
        return $?
    fi

    # warp-native does `cd "$HOME"` and skips registration when this file is
    # already there, so dropping one in is all it takes.
    local warp_home="${HOME:-/root}" acct
    acct="${warp_home}/wgcf-account.toml"
    if [[ -f "$acct" ]]; then
        info "existing $acct found — registration will be skipped"
    elif [[ -n "$WARP_ACCOUNT" ]]; then
        if materialise_file "$WARP_ACCOUNT" "$acct" 'private_key'; then
            ok "installed the supplied wgcf-account.toml"
        else
            soft_fail "supplied WARP account is not a readable wgcf-account.toml"
            return 1
        fi
    fi
    # The installer asks three questions: language, WARP+ licence, watchdog
    # interval. Empty answers take the defaults (English / free / 10 min).
    if ! curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh -o /tmp/warp-install.sh; then
        soft_fail "could not download the warp installer"
        return 1
    fi

    # Registration talks to api.cloudflareclient.com, which times out often
    # enough to be worth a second attempt.
    local attempt
    for attempt in 1 2; do
        if printf '1\n\n\n' | bash /tmp/warp-install.sh; then break; fi
        if (( attempt == 1 )); then
            warn "warp registration failed — retrying once in 15s"
            sleep 15
        fi
    done
    rm -f /tmp/warp-install.sh

    if systemctl is-active --quiet wg-quick@warp 2>/dev/null; then
        ok "warp tunnel up"
        return 0
    fi

    soft_fail "warp is not active — skipping, everything else is unaffected"
    warn "wgcf talks to api.cloudflareclient.com, which is commonly blocked from"
    warn "RU networks; that is what the TLS handshake timeout means."
    warn ""
    warn "To finish this later, copy from a machine where WARP already works:"
    warn ""
    warn "  # fully offline — the reliable one, needs no Cloudflare access:"
    warn "  scp -P ${SSH_PORT} /etc/wireguard/warp.conf root@${NODE_DOMAIN}:/etc/wireguard/warp.conf"
    warn "  ssh -p ${SSH_PORT} root@${NODE_DOMAIN} 'systemctl enable --now wg-quick@warp'"
    warn ""
    warn "  # or hand either file to this script on the next run:"
    warn "  warpprofile=/etc/wireguard/warp.conf     # or a URL, or base64"
    warn "  warpaccount=${warp_home}/wgcf-account.toml"
    warn ""
    warn "warpaccount= skips registration but 'wgcf generate' still calls the same"
    warn "blocked API, so prefer warpprofile= on a network like this one."
    return 1
}

install_beszel() {
    step "Beszel agent"
    if [[ -z "$BESZEL_KEY" ]]; then
        soft_fail "no hub public key — skipping the agent"
        warn "install it later with: curl -sL https://get.beszel.dev | sh -s -- -k '<key>' -p ${BESZEL_PORT} -t '<token>' -url ${BESZEL_HUB_URL}"
        return 1
    fi

    curl -sL https://get.beszel.dev -o /tmp/install-beszel.sh || {
        soft_fail "could not download the beszel installer"; return 1; }
    chmod +x /tmp/install-beszel.sh

    # -t/-url are optional; without a token the agent runs but does not
    # self-register, so the system has to be added on the hub by hand.
    local args=(-k "$BESZEL_KEY" -p "$BESZEL_PORT" -url "$BESZEL_HUB_URL")
    [[ -n "$BESZEL_TOKEN" ]] && args+=(-t "$BESZEL_TOKEN")

    # The agent binary comes from GitHub releases, which is unreachable from
    # some networks. The installer ships a proxy fallback for exactly this.
    if ! /tmp/install-beszel.sh "${args[@]}"; then
        warn "direct GitHub download failed — retrying via the mirror"
        if ! /tmp/install-beszel.sh "${args[@]}" --mirror; then
            rm -f /tmp/install-beszel.sh
            soft_fail "beszel agent install failed (direct and mirror)"
            warn "retry by hand with a proxy of your choice:"
            warn "  curl -sL https://get.beszel.dev -o /tmp/b.sh && sh /tmp/b.sh --mirror <url> \\"
            warn "    -k '<key>' -p ${BESZEL_PORT} -url ${BESZEL_HUB_URL}"
            return 1
        fi
    fi
    rm -f /tmp/install-beszel.sh
    sleep 3
    if systemctl is-active --quiet beszel-agent 2>/dev/null; then
        if [[ -n "$BESZEL_TOKEN" ]]; then
            ok "agent running — it should now appear on the hub automatically"
        else
            ok "agent running"
            warn "no token was available: add this system on the hub yourself"
            warn "  host ${NODE_DOMAIN}, port ${BESZEL_PORT}"
        fi
    else
        soft_fail "beszel-agent is not active — check: journalctl -u beszel-agent -n 50"
        return 1
    fi
}

SSHD_BACKUP=/etc/ssh/sshd_config.remnanode.bak

# Prepend Port to sshd_config itself, for images whose sshd_config has no
# Include line. Written via a temp file and copied back, so the original
# inode, owner and mode survive.
sshd_prepend_port() {
    grep -qE "^Port[[:space:]]+${SSH_PORT}\\b" /etc/ssh/sshd_config 2>/dev/null && return 0
    local tmp; tmp=$(mktemp)
    { printf '# Managed by install-node.sh\n'
      printf 'Port %s\n\n' "$SSH_PORT"
      cat /etc/ssh/sshd_config
    } > "$tmp"
    cat "$tmp" > /etc/ssh/sshd_config
    rm -f "$tmp"
}

ssh_rollback() {
    rm -f /etc/ssh/sshd_config.d/00-remnanode-port.conf
    [[ -f "$SSHD_BACKUP" ]] && cp -a "$SSHD_BACKUP" /etc/ssh/sshd_config
    return 0
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

    cp -a /etc/ssh/sshd_config "$SSHD_BACKUP" 2>/dev/null || true

    # sshd_config precedence is the opposite of most config systems: "for each
    # keyword, the FIRST obtained value will be used". Ubuntu puts the
    # Include for sshd_config.d at the top of sshd_config, so drop-ins are read
    # first, in glob order — a 99- file loses to 50-cloud-init.conf. Hence 00-,
    # plus commenting out every competing Port directive.
    local dropin=/etc/ssh/sshd_config.d/00-remnanode-port.conf
    mkdir -p /etc/ssh/sshd_config.d

    sed -i -E 's/^([[:space:]]*Port[[:space:]]+.*)$/# \1  # superseded by install-node.sh/' \
        /etc/ssh/sshd_config 2>/dev/null || true
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -e "$f" && "$f" != "$dropin" ]] || continue
        sed -i -E 's/^([[:space:]]*Port[[:space:]]+.*)$/# \1  # superseded by install-node.sh/' "$f" 2>/dev/null || true
    done

    printf '# Managed by install-node.sh\nPort %s\n' "$SSH_PORT" > "$dropin"

    # Does this image even read the drop-in directory? Some do not ship the
    # Include line, in which case the file above is inert.
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
        warn "sshd_config has no Include for sshd_config.d — writing Port directly"
        rm -f "$dropin"
        sshd_prepend_port
    fi

    if ! sshd -t 2>/dev/null; then
        ssh_rollback
        soft_fail "sshd rejected the new config — reverted, SSH left on port 22"
        return 1
    fi

    # Decisive check: ask sshd what it will actually bind, before restarting.
    local effective
    effective=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | tr '\n' ' ')
    if [[ " $effective " != *" $SSH_PORT "* ]]; then
        warn "effective sshd port is '${effective:-unknown}', not $SSH_PORT — retrying directly in sshd_config"
        rm -f "$dropin"
        sshd_prepend_port
        effective=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | tr '\n' ' ')
    fi
    if [[ " $effective " != *" $SSH_PORT "* ]]; then
        ssh_rollback
        soft_fail "could not make sshd use port $SSH_PORT (effective: ${effective:-unknown})"
        warn "something else in the config is pinning the port; SSH left on 22"
        return 1
    fi
    ok "sshd config resolves to port $SSH_PORT"

    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true

    local waited=0 listening=no
    while (( waited < 20 )); do
        if ss -tlnH "sport = :$SSH_PORT" 2>/dev/null | grep -q .; then listening=yes; break; fi
        sleep 1; waited=$((waited + 1))
    done

    if [[ "$listening" == "yes" ]]; then
        ufw delete allow 22/tcp >/dev/null 2>&1 || true
        SSH_MIGRATED=yes
        ok "sshd listening on $SSH_PORT — port 22 closed"
        warn "your current session stays alive; new logins must use: ssh -p $SSH_PORT root@$NODE_DOMAIN"
    else
        warn "sshd did not bind $SSH_PORT. Last journal lines:"
        journalctl -u ssh -u sshd -n 15 --no-pager 2>/dev/null | sed 's/^/       /' || true
        ssh_rollback
        systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
        soft_fail "nothing came up on $SSH_PORT — rolled back, port 22 left open"
        return 1
    fi
}

summary() {
    step "Done"

    if ((${#FAILED_STEPS[@]})); then
        printf '\n     %sFinished with %d step(s) skipped or failed:%s\n' \
            "$C_YEL" "${#FAILED_STEPS[@]}" "$C_RESET"
        local f
        for f in "${FAILED_STEPS[@]}"; do printf '       %s✗%s %s\n' "$C_RED" "$C_RESET" "$f"; done
        printf '     %sThe node itself is up; re-run to retry just these.%s\n' "$C_YEL" "$C_RESET"
    fi

    cat <<SUMMARY

     ${C_GRN}Node provisioned.${C_RESET}

       Panel node    ${NODE_NAME}  ->  ${NODE_DOMAIN}:${NODE_PORT}${REGISTERED_UUID:+  (${REGISTERED_UUID})}
       DNS           $([[ "$MANAGE_DNS" == "yes" ]] && echo "A ${NODE_DOMAIN} -> ${PUBLIC_IP} (reg.ru)" || echo "managed manually")
       Selfsteal     https://${NODE_DOMAIN}  (Caddy TLS :${SELFSTEAL_PORT}, plaintext :${FALLBACK_PORT})
       TLS cert      ${CERT_PATH:-none mounted}
       SSH           $([[ "${SSH_MIGRATED:-no}" == "yes" ]] && echo "port ${SSH_PORT}" || echo "port 22 (unchanged)")
       Beszel        $(hostname) -> ${BESZEL_HUB_URL}
       IPv6          $([[ "$DISABLE_IPV6" == "yes" ]] && echo disabled || echo enabled)
       Congestion    $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)
       Log           ${LOG_FILE}

     ${C_YEL}What this script cannot do for you:${C_RESET}
       1. $([[ "$MANAGE_DNS" == "yes" ]] \
            && echo "Nothing on the DNS side — the A record was created for you." \
            || echo "The A record for ${NODE_DOMAIN} must be DNS-only (grey cloud); a
          proxied Cloudflare record stops the panel reaching port ${NODE_PORT}.")
       2. In the panel, your Reality inbound's serverNames must include
          ${NODE_DOMAIN} and its dest must point at 127.0.0.1:${SELFSTEAL_PORT}.
          A VLESS-TCP-TLS inbound instead needs settings.fallbacks[].dest =
          ${FALLBACK_PORT} plus tlsSettings.alpn = ["http/1.1"] — its fallback
          gets decrypted bytes, so it must not point at :${SELFSTEAL_PORT}.

     Useful commands:
       docker logs -f remnanode
       ufw status numbered
       warp
       systemctl status beszel-agent

SUMMARY
}

# --- Torrent guard ---------------------------------------------------------
# Xray's sniffer only recognises unencrypted BitTorrent, so a client with
# protocol encryption switched on walks straight past the panel's routing
# rules. This closes that gap on the node itself.
#
# It hooks `output`, so it sees what the node originates — including traffic
# routed into WARP, which crosses `output` before encapsulation. Client-facing
# traffic is accepted up front, which also makes the guard indifferent to
# whether the node sits behind a CDN.
#
# Its own table, `policy accept` plus explicit drops: it cannot interfere with
# ufw, with Docker's chains, or with the Remnawave node plugin's table.
install_torrent_guard() {
    step "Torrent guard (nftables)"

    if ! have nft; then
        soft_fail "nftables is not installed"
        return 1
    fi

    # Ports we must never mistake for torrent traffic. A client's ephemeral
    # source port can legitimately land inside the BitTorrent ranges — 51413
    # sits inside the Windows ephemeral range 49152-65535 — so replies to our
    # own clients are accepted before any port rule is consulted.
    local svc_ports="${SHAPE_PORTS},${NODE_PORT},${SSH_PORT},${BESZEL_PORT},${SELFSTEAL_PORT},${FALLBACK_PORT}"

    cat > "$GUARD_NFT" <<GUARD
#!/usr/sbin/nft -f
# Written by install-node.sh. Reloaded by rw-torrent-guard.service.
# Blocks what Xray cannot see: DHT, UDP trackers, and the classic BitTorrent
# port ranges — on traffic this node sends out.

table inet rw_torrent_guard
delete table inet rw_torrent_guard

table inet rw_torrent_guard {
    set bt_ports {
        type inet_service
        flags interval
        elements = { 6881-6889, 51413, 21413, 17417, 37305 }
    }

    counter c_udp_tracker {}
    counter c_dht {}
    counter c_ports {}

    chain out {
        type filter hook output priority 10; policy accept;

        oifname "lo" accept
        udp dport 53 accept
        tcp dport 53 accept

        # Replies to our own clients and to the control plane. Must precede
        # the port rules — see the note above about ephemeral source ports.
        tcp sport { ${svc_ports} } accept
        udp sport { ${svc_ports} } accept

        # UDP tracker connect: the 8-byte magic 0x41727101980 at the start of
        # the UDP payload. The UDP header is 8 bytes, so the payload begins at
        # bit offset 64 from the transport header.
        meta l4proto udp @th,64,64 0x0000041727101980 counter name c_udp_tracker drop

        # DHT, bencoded: queries open "d1:ad2:i", replies "d1:rd2:i".
        # Matched unconditionally — DHT is stateless UDP, so the interesting
        # packets are not all ct state new.
        meta l4proto udp @th,64,64 0x64313a6164323a69 counter name c_dht drop
        meta l4proto udp @th,64,64 0x64313a7264323a69 counter name c_dht drop

        # Port rules apply to the opening packet only: the connection never
        # establishes, and anything already running is left alone.
        ct state new tcp dport @bt_ports counter name c_ports drop
        ct state new udp dport @bt_ports counter name c_ports drop
    }
}
GUARD
    chmod 644 "$GUARD_NFT"

    if ! nft -c -f "$GUARD_NFT" 2>/tmp/rwguard.err; then
        soft_fail "the ruleset did not validate: $(tr -d '\n' </tmp/rwguard.err)"
        info "kernel $(uname -r), nft $(nft --version 2>/dev/null | head -1)"
        return 1
    fi

    cat > /etc/systemd/system/rw-torrent-guard.service <<'UNIT'
[Unit]
Description=Torrent guard (nftables rules for DHT, UDP trackers, BitTorrent ports)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/rw-torrent-guard.nft
ExecReload=/usr/sbin/nft -f /etc/rw-torrent-guard.nft
ExecStop=-/usr/sbin/nft delete table inet rw_torrent_guard

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    if systemctl enable --now rw-torrent-guard.service >/dev/null 2>&1; then
        ok "loaded and enabled at boot"
    else
        soft_fail "could not start rw-torrent-guard.service"
        systemctl status rw-torrent-guard.service --no-pager -l 2>&1 | sed 's/^/       /' | head -15
        return 1
    fi

    # Prove the table is actually live rather than trusting the exit code.
    if nft list table inet rw_torrent_guard >/dev/null 2>&1; then
        ok "table inet rw_torrent_guard is active"
    else
        soft_fail "the service started but the table is not present"
        return 1
    fi
    info "counters:  nft list counters table inet rw_torrent_guard"
    info "disable:   systemctl disable --now rw-torrent-guard"
}

# --- Speed shaper ----------------------------------------------------------
# A client that sustains more than SHAPE_TRIGGER_MBIT for SHAPE_TRIGGER_SECONDS
# is held to SHAPE_CAP_MBIT until it goes quiet again.
#
# nftables does the accounting (one dynamic set of client addresses with
# per-element byte counters); tc does the enforcement (HTB on the WAN device
# for download, on an ifb for upload). No fwmark is involved: tc ingress runs
# before netfilter, so marks are not available on the ifb path, and matching
# addresses directly in u32 keeps both directions consistent.
install_speed_shaper() {
    step "Speed shaper (>${SHAPE_TRIGGER_MBIT} Mbit/s for ${SHAPE_TRIGGER_SECONDS}s -> ${SHAPE_CAP_MBIT} Mbit/s)"

    if ! have nft; then
        soft_fail "nftables is not installed"
        return 1
    fi
    if ! have tc; then
        info "installing: iproute2"
        apt-get install -y -qq iproute2 >/dev/null 2>&1 || true
    fi

    local wan
    wan=$(ip -4 route get 1.1.1.1 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    if [[ -z "$wan" ]]; then
        soft_fail "could not work out which interface faces the internet"
        return 1
    fi
    ok "WAN interface: $wan"

    # The panel must never be shaped, and neither should whoever is currently
    # logged in over SSH.
    local ignore="$SHAPE_IGNORE_IPS"
    [[ -n "$PANEL_IP" ]] && ignore="$ignore $PANEL_IP"
    [[ -n "${SSH_CLIENT:-}" ]] && ignore="$ignore ${SSH_CLIENT%% *}"

    cat > "$SHAPER_CONF" <<CONF
# rw-shaper — written by install-node.sh, edit and restart to change.
#   systemctl restart rw-shaper
WAN=$wan
PORTS=$SHAPE_PORTS
TICK=10
TRIGGER_MBIT=$SHAPE_TRIGGER_MBIT
TRIGGER_SECONDS=$SHAPE_TRIGGER_SECONDS
CAP_MBIT=$SHAPE_CAP_MBIT
RELEASE_MBIT=$SHAPE_RELEASE_MBIT
RELEASE_SECONDS=$SHAPE_RELEASE_SECONDS
SHAPE_UPLOAD=$SHAPE_UPLOAD
MAX_CLIENTS=$SHAPE_MAX_CLIENTS
MAX_CONNS=$SHAPE_MAX_CONNS
IGNORE_IPS="$(printf '%s' "$ignore" | tr ',' ' ' | xargs 2>/dev/null || true)"
CONF
    chmod 600 "$SHAPER_CONF"

    materialise_shaper_daemon || return 1

    cat > /etc/systemd/system/rw-shaper.service <<'UNIT'
[Unit]
Description=Speed shaper — hold sustained heavy clients to a fixed cap
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rw-shaper
Restart=always
RestartSec=5
# The daemon tears down its own tc qdiscs and nft table on SIGTERM.
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    if systemctl enable --now rw-shaper.service >/dev/null 2>&1; then
        ok "running and enabled at boot"
    else
        soft_fail "could not start rw-shaper.service"
        journalctl -u rw-shaper -n 20 --no-pager 2>&1 | sed 's/^/       /'
        return 1
    fi

    sleep 2
    if systemctl is-active --quiet rw-shaper; then
        ok "trigger ${SHAPE_TRIGGER_MBIT} Mbit/s combined, cap ${SHAPE_CAP_MBIT} Mbit/s each way"
        [[ "${SHAPE_UPLOAD,,}" == yes ]] \
            && info "upload shaping on (all inbound traffic crosses an ifb)" \
            || info "upload shaping off — download only"
    else
        soft_fail "rw-shaper exited right after starting"
        journalctl -u rw-shaper -n 20 --no-pager 2>&1 | sed 's/^/       /'
        return 1
    fi
    info "watch:     journalctl -fu rw-shaper"
    info "status:    $0  ->  menu option 18"
}

# Split out from install_speed_shaper purely so neither function is too long to
# hold in your head at once. The daemon is written verbatim — the quoted
# heredoc means nothing here is expanded at install time; it reads its settings
# from /etc/rw-shaper.conf at run time.
materialise_shaper_daemon() {
    cat > "$SHAPER_BIN" <<'SHAPER'
#!/usr/bin/env bash
# rw-shaper — hold a client that sustains heavy throughput down to a fixed cap.
#
# nftables counts bytes per client address; tc enforces. Every threshold is
# integer bytes-per-second, so there is no floating point anywhere.
set -uo pipefail

CONF=/etc/rw-shaper.conf
# shellcheck disable=SC1090
[[ -r $CONF ]] && . "$CONF"

: "${WAN:=}"
: "${PORTS:=443}"
: "${TICK:=10}"
: "${TRIGGER_MBIT:=100}"
: "${TRIGGER_SECONDS:=120}"
: "${CAP_MBIT:=8}"
: "${RELEASE_MBIT:=4}"
: "${RELEASE_SECONDS:=300}"
: "${SHAPE_UPLOAD:=yes}"
: "${MAX_CLIENTS:=64}"
: "${MAX_CONNS:=200}"
: "${IGNORE_IPS:=}"

TABLE=rw_shaper
IFB=ifb-rwshape

log() { printf '%s rw-shaper: %s\n' "$(date -Is)" "$*"; }

[[ -z $WAN ]] && WAN=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
if [[ -z $WAN ]]; then log "no WAN interface"; exit 1; fi

# 1 Mbit/s = 125000 bytes/s.
TRIGGER_BPS=$(( TRIGGER_MBIT * 125000 ))
RELEASE_BPS=$(( RELEASE_MBIT * 125000 ))
TRIGGER_TICKS=$(( (TRIGGER_SECONDS + TICK - 1) / TICK ))
RELEASE_TICKS=$(( (RELEASE_SECONDS + TICK - 1) / TICK ))
UPLOAD=no
[[ ${SHAPE_UPLOAD,,} == yes ]] && UPLOAD=yes

# HTB needs a ceiling for the root class. A VM often reports no link speed at
# all, in which case a deliberately huge ceiling keeps the default class from
# throttling anything.
link_rate() {
    local s
    s=$(cat "/sys/class/net/$WAN/speed" 2>/dev/null || true)
    if [[ $s =~ ^[0-9]+$ ]] && (( s > 0 )); then printf '%smbit' "$s"; else printf '10gbit'; fi
}

nft_setup() {
    nft delete table inet $TABLE 2>/dev/null
    nft -f - <<NFT
table inet $TABLE {
    set clients {
        type ipv4_addr
        size 65535
        flags dynamic,timeout
        timeout 10m
        counter
    }
    chain meter_in {
        type filter hook prerouting priority -150; policy accept;
        iifname "$WAN" tcp dport { $PORTS } update @clients { ip saddr }
        iifname "$WAN" udp dport { $PORTS } update @clients { ip saddr }
    }
    chain meter_out {
        type filter hook postrouting priority -150; policy accept;
        oifname "$WAN" tcp sport { $PORTS } update @clients { ip daddr }
        oifname "$WAN" udp sport { $PORTS } update @clients { ip daddr }
    }
}
NFT
}

# The default class keeps `fq` as its leaf so BBR still paces normally; only
# shaped classes get fq_codel, where pacing is not the point.
tc_setup() {
    local rate; rate=$(link_rate)
    tc qdisc del dev "$WAN" root 2>/dev/null
    tc qdisc add dev "$WAN" root handle 1: htb default 10
    tc class add dev "$WAN" parent 1: classid 1:1 htb rate "$rate" ceil "$rate"
    tc class add dev "$WAN" parent 1:1 classid 1:10 htb rate "$rate" ceil "$rate"
    tc qdisc add dev "$WAN" parent 1:10 handle 10: fq 2>/dev/null

    [[ $UPLOAD == yes ]] || return 0
    modprobe ifb numifbs=0 2>/dev/null
    ip link show "$IFB" >/dev/null 2>&1 || ip link add "$IFB" type ifb
    ip link set "$IFB" up
    tc qdisc del dev "$WAN" ingress 2>/dev/null
    tc qdisc add dev "$WAN" handle ffff: ingress
    tc filter add dev "$WAN" parent ffff: protocol all prio 1 u32 \
        match u32 0 0 action mirred egress redirect dev "$IFB"
    tc qdisc del dev "$IFB" root 2>/dev/null
    tc qdisc add dev "$IFB" root handle 1: htb default 10
    tc class add dev "$IFB" parent 1: classid 1:1 htb rate "$rate" ceil "$rate"
    tc class add dev "$IFB" parent 1:1 classid 1:10 htb rate "$rate" ceil "$rate"
    tc qdisc add dev "$IFB" parent 1:10 handle 10: fq_codel 2>/dev/null
}

declare -A PREV OVER QUIET CLASSID

# Each shaped address gets its own tc priority as well as its own class, so the
# filter can be removed later by priority alone — u32 handles are awkward to
# recover once added.
alloc_minor() {
    local m k used
    for (( m = 100; m < 100 + MAX_CLIENTS; m++ )); do
        used=no
        for k in "${!CLASSID[@]}"; do
            [[ ${CLASSID[$k]} == "$m" ]] && { used=yes; break; }
        done
        [[ $used == no ]] && { printf '%s' "$m"; return 0; }
    done
    return 1
}

shape() {  # shape <ip>
    local ip=$1 m
    m=$(alloc_minor) || { log "at the $MAX_CLIENTS-client limit, leaving $ip alone"; return 1; }
    tc class add dev "$WAN" parent 1:1 classid "1:$m" \
        htb rate "${CAP_MBIT}mbit" ceil "${CAP_MBIT}mbit" 2>/dev/null || return 1
    tc qdisc add dev "$WAN" parent "1:$m" handle "$m:" fq_codel 2>/dev/null
    tc filter add dev "$WAN" protocol ip parent 1: prio "$m" u32 \
        match ip dst "$ip/32" flowid "1:$m" 2>/dev/null || return 1
    if [[ $UPLOAD == yes ]]; then
        tc class add dev "$IFB" parent 1:1 classid "1:$m" \
            htb rate "${CAP_MBIT}mbit" ceil "${CAP_MBIT}mbit" 2>/dev/null
        tc qdisc add dev "$IFB" parent "1:$m" handle "$m:" fq_codel 2>/dev/null
        tc filter add dev "$IFB" protocol ip parent 1: prio "$m" u32 \
            match ip src "$ip/32" flowid "1:$m" 2>/dev/null
    fi
    CLASSID[$ip]=$m
    log "shaping $ip to ${CAP_MBIT}mbit (class 1:$m)"
}

release() {  # release <ip>
    local ip=$1
    local m=${CLASSID[$ip]:-}
    [[ -z $m ]] && return 0
    tc filter del dev "$WAN" parent 1: prio "$m" 2>/dev/null
    tc class del dev "$WAN" classid "1:$m" 2>/dev/null
    if [[ $UPLOAD == yes ]]; then
        tc filter del dev "$IFB" parent 1: prio "$m" 2>/dev/null
        tc class del dev "$IFB" classid "1:$m" 2>/dev/null
    fi
    unset "CLASSID[$ip]"
    log "released $ip"
}

# Loopback, RFC1918 and CGNAT space, plus anything explicitly exempted.
ignored() {  # ignored <ip>
    local ip=$1 x
    case $ip in
        0.0.0.0|127.*|10.*|169.254.*|192.168.*)  return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)   return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
    esac
    for x in $IGNORE_IPS; do [[ $ip == "$x" ]] && return 0; done
    return 1
}

conn_count() { ss -tnH "dst $1" 2>/dev/null | wc -l; }

read_counters() {
    nft -j list set inet $TABLE clients 2>/dev/null | jq -r '
        .nftables[]? | .set? // empty | .elem[]? | (.elem // .)
        | select(type == "object") | select(.counter != null)
        | "\(.val) \(.counter.bytes)"' 2>/dev/null
}

teardown() {
    local ip
    log "stopping, undoing everything"
    for ip in "${!CLASSID[@]}"; do release "$ip"; done
    tc qdisc del dev "$WAN" root 2>/dev/null
    tc qdisc del dev "$WAN" ingress 2>/dev/null
    if [[ $UPLOAD == yes ]]; then
        tc qdisc del dev "$IFB" root 2>/dev/null
        ip link del "$IFB" 2>/dev/null
    fi
    nft delete table inet $TABLE 2>/dev/null
    # Restore the plain fq that tune_kernel expects to find on the interface.
    tc qdisc add dev "$WAN" root fq 2>/dev/null
    exit 0
}
trap teardown INT TERM

nft_setup || { log "could not install the accounting table"; exit 1; }
tc_setup  || { log "could not set up tc"; exit 1; }
log "watching $WAN ports $PORTS — trigger ${TRIGGER_MBIT}mbit for ${TRIGGER_SECONDS}s, cap ${CAP_MBIT}mbit, release below ${RELEASE_MBIT}mbit for ${RELEASE_SECONDS}s"

while :; do
    sleep "$TICK"
    declare -A seen=()

    while read -r ip bytes; do
        [[ -z ${ip:-} || -z ${bytes:-} ]] && continue
        seen[$ip]=1
        prev=${PREV[$ip]:-}
        PREV[$ip]=$bytes
        # No previous sample, or the element aged out and came back with a
        # fresh counter: start again rather than reporting a negative rate.
        [[ -z $prev ]] && continue
        (( bytes < prev )) && continue
        rate=$(( (bytes - prev) / TICK ))

        if [[ -n ${CLASSID[$ip]:-} ]]; then
            # Already shaped, so the measured rate sits at the cap while they
            # keep pulling. Release on falling well below it, not below the
            # trigger, which they can no longer reach.
            if (( rate < RELEASE_BPS )); then
                QUIET[$ip]=$(( ${QUIET[$ip]:-0} + 1 ))
                if (( ${QUIET[$ip]} >= RELEASE_TICKS )); then
                    release "$ip"; unset "QUIET[$ip]" "OVER[$ip]"
                fi
            else
                QUIET[$ip]=0
            fi
            continue
        fi

        if (( rate < TRIGGER_BPS )); then
            OVER[$ip]=0
            continue
        fi

        OVER[$ip]=$(( ${OVER[$ip]:-0} + 1 ))
        (( ${OVER[$ip]} < TRIGGER_TICKS )) && continue
        OVER[$ip]=0

        if ignored "$ip"; then continue; fi
        # Only checked when a shape is imminent, which is rare. Doing it every
        # tick would mean walking the whole socket table on a busy node.
        conns=$(conn_count "$ip")
        if (( conns > MAX_CONNS )); then
            log "not shaping $ip: $conns concurrent connections looks like a CDN edge or CGNAT, not one client"
            continue
        fi
        shape "$ip" && QUIET[$ip]=0
    done < <(read_counters)

    # Drop bookkeeping for addresses that have left the set, so the arrays do
    # not grow without bound on a long-lived node.
    for ip in "${!PREV[@]}"; do
        [[ -n ${seen[$ip]:-} ]] && continue
        [[ -n ${CLASSID[$ip]:-} ]] && release "$ip"
        unset "PREV[$ip]" "OVER[$ip]" "QUIET[$ip]"
    done
    unset seen
done
SHAPER
    chmod 755 "$SHAPER_BIN"
    if ! bash -n "$SHAPER_BIN"; then
        soft_fail "the generated daemon has a syntax error"
        return 1
    fi
    ok "daemon written to $SHAPER_BIN"
}

# --- Guard status ----------------------------------------------------------
# One place to answer "is any of this actually doing anything?".
guard_status() {
    step "Torrent guard / speed shaper status"

    printf '\n     %sTorrent guard%s\n' "$C_BLU" "$C_RESET"
    if nft list table inet rw_torrent_guard >/dev/null 2>&1; then
        ok "table active"
        nft -j list counters table inet rw_torrent_guard 2>/dev/null | jq -r '
            .nftables[]? | .counter? // empty
            | "       \(.name): \(.packets) packets, \(.bytes) bytes"' 2>/dev/null \
            || nft list counters table inet rw_torrent_guard 2>/dev/null | sed 's/^/       /'
        info "all three at zero on a busy node means nothing is reaching them —"
        info "check the panel routing before assuming clients are behaving"
    else
        warn "not loaded (menu option 16 installs it)"
    fi

    printf '\n     %sSpeed shaper%s\n' "$C_BLU" "$C_RESET"
    if ! systemctl is-active --quiet rw-shaper 2>/dev/null; then
        warn "rw-shaper is not running (menu option 17 installs it)"
        return 0
    fi
    ok "rw-shaper running"

    local wan=""
    [[ -r "$SHAPER_CONF" ]] && wan=$(awk -F= '$1=="WAN"{print $2}' "$SHAPER_CONF")
    [[ -n "$wan" ]] && info "interface: $wan"

    # Classes below 1:10 are the per-offender ones; 1:1 and 1:10 are structural.
    local shaped
    shaped=$(tc -s class show dev "$wan" 2>/dev/null \
             | awk '/class htb 1:1[0-9][0-9]/ {print $3}' | tr '\n' ' ')
    if [[ -n "${shaped// /}" ]]; then
        warn "currently shaped classes: $shaped"
        tc filter show dev "$wan" 2>/dev/null \
            | grep -Eo 'match [0-9a-f]{8}/ffffffff' | sed 's/^/       /' | head -20
    else
        ok "nobody is being shaped right now"
    fi

    # Two samples two seconds apart turns the running byte counters into rates.
    if nft list set inet rw_shaper clients >/dev/null 2>&1; then
        local a b
        a=$(nft -j list set inet rw_shaper clients 2>/dev/null | jq -c '[.nftables[]?|.set?//empty|.elem[]?|(.elem//.)|select(.counter!=null)|{(.val|tostring):.counter.bytes}]|add // {}')
        sleep 2
        b=$(nft -j list set inet rw_shaper clients 2>/dev/null | jq -c '[.nftables[]?|.set?//empty|.elem[]?|(.elem//.)|select(.counter!=null)|{(.val|tostring):.counter.bytes}]|add // {}')
        printf '\n     top clients by current throughput\n'
        jq -rn --argjson a "$a" --argjson b "$b" '
            [ $b | to_entries[]
              | select($a[.key] != null and .value >= $a[.key])
              | {ip: .key, mbit: (((.value - $a[.key]) * 8 / 2 / 1000000) * 10 | round / 10)} ]
            | sort_by(-.mbit) | .[:10] | .[]
            | "       \(.ip)  \(.mbit) Mbit/s"' 2>/dev/null \
            || info "no samples yet"
    fi
}

run_all() {
    need_panel
    need_domain
    need_node_name
    need_beszel
    need_ipv6
    [[ "$MANAGE_DNS" == "yes" ]] && need_regru
    resolve_config_profile

    beszel_login       || true
    setup_dns          || true
    install_docker
    tune_kernel        || true
    configure_ufw      || true
    await_dns          || true
    install_selfsteal  || true
    configure_fallback_site || true
    locate_certs       || true
    install_remnanode
    install_cert_watcher || true
    register_node
    install_warp       || true
    install_beszel     || true
    # After tune_kernel and install_warp: the shaper takes over the interface's
    # root qdisc, and the guard wants the WARP interface to already exist.
    [[ "${SKIP_TORRENT_GUARD,,}" == yes ]] || install_torrent_guard || true
    [[ "${SKIP_SHAPER,,}" == yes ]]        || install_speed_shaper  || true
    migrate_ssh        || true
    summary
}

# --- Optional extras -------------------------------------------------------
# Neither of these runs as part of a full install: zapret's installer is
# interactive by design, and it rewrites nftables/iptables rules on a box that
# is already carrying ufw, Docker and Xray. Both live in the menu only.

# Test 4 of dpi-detector: TCP 16-20KB blocking — connections to CDNs and
# hostings killed after ~14-34KB. Read the result before and after touching
# zapret; the tool's own README notes an active bypass distorts the numbers.
run_dpi_check() {
    step "DPI check — TCP 16-20KB blocking (dpi-detector test 4)"
    if ! have docker; then
        soft_fail "docker is not installed — run menu option 2 first"
        return 1
    fi
    mkdir -p "$DPI_LOG_DIR"
    local out
    out="${DPI_LOG_DIR}/${1:-check}-$(date +%Y%m%d-%H%M%S).log"
    info "ghcr.io/runnin4ik/dpi-detector:latest -t 4 --batch"
    info "this takes a couple of minutes"
    echo
    if docker run --rm --pull=always ghcr.io/runnin4ik/dpi-detector:latest \
            -t 4 --batch 2>&1 | tee "$out"; then
        echo
        ok "saved to $out"
        return 0
    fi
    soft_fail "dpi-detector did not complete"
    return 1
}

# Set a key in zapret's config, replacing the shipped (often commented) line.
zapret_set_cfg() {  # zapret_set_cfg <key> <value>
    local f="$ZAPRET_DIR/config" k=$1 v=$2
    if grep -qE "^[#[:space:]]*${k}=" "$f" 2>/dev/null; then
        sed -i -E "s|^[#[:space:]]*${k}=.*|${k}=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

install_zapret() {
    step "Zapret (DPI bypass)"

    if systemctl is-active --quiet zapret 2>/dev/null; then
        ok "zapret is already running"
        info "reconfigure:      $ZAPRET_DIR/install_easy.sh"
        info "find a strategy:  $ZAPRET_DIR/blockcheck.sh"
        return 0
    fi

    warn "zapret inserts NFQUEUE rules into nftables/iptables. This box already"
    warn "runs ufw, Docker and Xray, so take the node out of rotation first if"
    warn "you cannot afford a blip."
    echo

    local tag url tmp
    tag=$(curl -sSL --max-time 30 https://api.github.com/repos/bol-van/zapret/releases/latest \
          | jq -r '.tag_name // empty' 2>/dev/null || true)
    if [[ -z "$tag" ]]; then
        soft_fail "could not resolve the latest zapret release"
        return 1
    fi
    info "latest release: $tag"

    tmp=$(mktemp -d)
    url="https://github.com/bol-van/zapret/releases/download/${tag}/zapret-${tag}.tar.gz"
    if ! curl -fSL --max-time 300 "$url" -o "$tmp/zapret.tar.gz"; then
        rm -rf "$tmp"
        soft_fail "could not download $url"
        warn "GitHub releases are often unreachable from RU networks — fetch the"
        warn "tarball elsewhere, drop it in $tmp, and run $ZAPRET_DIR/install_easy.sh"
        return 1
    fi

    # sha256sum.txt does NOT cover the tarball — it lists the binaries *inside*
    # it, with paths relative to the extraction directory. So unpack first, then
    # verify the tree.
    local have_sums=no sums_code=""
    local sums_url="https://github.com/bol-van/zapret/releases/download/${tag}/sha256sum.txt"
    local try
    for try in 1 2 3; do
        sums_code=$(curl -sSL --max-time 60 -w '%{http_code}' "$sums_url" \
                    -o "$tmp/sha256sum.txt" 2>/dev/null || echo 000)
        if [[ "$sums_code" == "200" && -s "$tmp/sha256sum.txt" ]]; then
            have_sums=yes; break
        fi
        (( try < 3 )) && sleep 3
    done

    rm -rf "/opt/zapret-${tag}"
    if ! tar -xzf "$tmp/zapret.tar.gz" -C /opt; then
        rm -rf "$tmp"
        soft_fail "could not unpack zapret"
        return 1
    fi

    if [[ "$have_sums" == "yes" ]]; then
        local bad
        bad=$(cd /opt && sha256sum -c "$tmp/sha256sum.txt" 2>/dev/null | grep -c 'FAILED' || true)
        if [[ "${bad:-0}" -gt 0 ]]; then
            rm -rf "/opt/zapret-${tag}" "$tmp"
            soft_fail "$bad file(s) failed checksum verification — refusing to install"
            return 1
        fi
        ok "checksums verified"
    else
        warn "could not fetch sha256sum.txt after 3 tries (HTTP ${sums_code:-?}) — installing unverified"
    fi
    rm -rf "$tmp"

    local saved_cfg=""
    if [[ -f "$ZAPRET_DIR/config" ]]; then
        saved_cfg=$(mktemp)
        cp -f "$ZAPRET_DIR/config" "$saved_cfg"
    fi
    if [[ -d "$ZAPRET_DIR" ]]; then
        info "moving the existing $ZAPRET_DIR aside"
        mv -f "$ZAPRET_DIR" "${ZAPRET_DIR}.bak.$(date +%s)"
    fi
    mv -f "/opt/zapret-${tag}" "$ZAPRET_DIR"

    # install_easy.sh copies config.default to config and sources it, then uses
    # each variable's current value as that question's default. So seeding the
    # config first turns the interview into "press Enter twelve times" — and
    # without it NFQWS_ENABLE defaults to 0, which installs zapret with every
    # mode switched off and a service that refuses to start.
    if [[ -n "$saved_cfg" ]]; then
        cp -f "$saved_cfg" "$ZAPRET_DIR/config"; rm -f "$saved_cfg"
        ok "kept your existing zapret config"
    else
        cp -f "$ZAPRET_DIR/config.default" "$ZAPRET_DIR/config"
        zapret_set_cfg FWTYPE nftables
        zapret_set_cfg NFQWS_ENABLE 1
        zapret_set_cfg TPWS_ENABLE 0
        zapret_set_cfg TPWS_SOCKS_ENABLE 0
        zapret_set_cfg MODE_FILTER none
        zapret_set_cfg FLOWOFFLOAD donttouch
        zapret_set_cfg IFACE_LAN ""
        zapret_set_cfg IFACE_WAN ""
        zapret_set_cfg DISABLE_IPV6 "$([[ "$DISABLE_IPV6" == "yes" ]] && echo 1 || echo 0)"
        ok "seeded $ZAPRET_DIR/config for a server (nfqws on, no filtering, no LAN interface)"
    fi
    if [[ ! -x "$ZAPRET_DIR/install_easy.sh" ]]; then
        soft_fail "unpacked, but $ZAPRET_DIR/install_easy.sh is missing"
        return 1
    fi
    ok "unpacked to $ZAPRET_DIR"

    echo
    info "handing over to zapret's own installer."
    info "the config above already sets every answer, so you can press Enter"
    info "at each prompt. The one that matters is 'enable nfqws ?' — it must"
    info "say (default : Y). Answer NONE to 'LAN interface' on a VPS; picking a"
    info "real interface there sets up router forwarding rules you do not want."
    echo
    "$ZAPRET_DIR/install_easy.sh" < /dev/tty || {
        soft_fail "install_easy.sh exited non-zero"
        return 1
    }

    if systemctl is-active --quiet zapret 2>/dev/null; then
        ok "zapret service is running"
    elif [[ "$(grep -E '^NFQWS_ENABLE=' "$ZAPRET_DIR/config" 2>/dev/null | tail -1)" == "NFQWS_ENABLE=0" ]]; then
        soft_fail "zapret installed with every mode disabled — nothing to run"
        warn "you answered N to 'enable nfqws ?'. Fix it with either:"
        warn "  sed -i 's/^NFQWS_ENABLE=0/NFQWS_ENABLE=1/' $ZAPRET_DIR/config && systemctl restart zapret"
        warn "  $ZAPRET_DIR/install_easy.sh     # and answer Y to nfqws"
    else
        soft_fail "zapret is installed but the service is not active"
        warn "check: systemctl status zapret; journalctl -u zapret -n 30"
    fi
    info "to search for a working strategy, run: $ZAPRET_DIR/blockcheck.sh"
    return 0
}

# blockcheck is zapret's own strategy finder. It must run with every bypass
# stopped — its first check warns about this, and if nfqws is live its own
# NFQUEUE redirection collides with the running rules and every nfqws test
# fails with a timeout, which looks like "nothing works" after an hour or two.
run_blockcheck() {
    step "Find a working strategy (zapret blockcheck)"
    if [[ ! -x "$ZAPRET_DIR/blockcheck.sh" ]]; then
        soft_fail "$ZAPRET_DIR/blockcheck.sh not found — install zapret first (13)"
        return 1
    fi

    local was_active=no
    if systemctl is-active --quiet zapret 2>/dev/null; then
        was_active=yes
        info "stopping zapret so the results are not distorted"
        systemctl stop zapret >/dev/null 2>&1 || true
        sleep 2
    fi

    warn "this is slow: 'standard' mode tries well over a thousand combinations,"
    warn "and every failing one burns its full timeout. Budget 1.5-2.5 hours."
    warn "Choose 'quick' (1) at the scan-mode prompt to stop at the first hit —"
    warn "usually minutes instead of hours."
    echo

    "$ZAPRET_DIR/blockcheck.sh" < /dev/tty || warn "blockcheck exited non-zero"

    if [[ "$was_active" == "yes" ]]; then
        info "restarting zapret"
        systemctl start zapret >/dev/null 2>&1 || warn "could not restart zapret"
    fi
    info "put the winning options into NFQWS_OPT in $ZAPRET_DIR/config,"
    info "then: systemctl restart zapret  — and re-check with menu option 14"
    return 0
}

# --- Menu ------------------------------------------------------------------

action_done() {
    if ((${#FAILED_STEPS[@]})); then
        printf '
     %s%d step(s) reported a problem:%s
' "$C_YEL" "${#FAILED_STEPS[@]}" "$C_RESET"
        local f
        for f in "${FAILED_STEPS[@]}"; do printf '       %s✗%s %s
' "$C_RED" "$C_RESET" "$f"; done
        FAILED_STEPS=()
    fi
    printf '
'
    prompt "press Enter to return to the menu: "
    read -r _ < /dev/tty || true
}

show_menu() {
    cat <<MENU

${C_BLU}  Remnawave node setup${C_RESET}  —  $(hostname)${PUBLIC_IP:+  ($PUBLIC_IP)}

    1)  Full install               everything below, in order
    2)  Remnanode container        fetch key, write compose, start it
    3)  Link TLS certificates      mount selfsteal's cert into Xray + renewal watch
    4)  Selfsteal site             Caddy masquerade + plaintext fallback listener
    5)  Fallback listener only     the plaintext :${FALLBACK_PORT} vhost for VLESS/TLS
    6)  Register node in panel     POST /api/nodes
    7)  DNS A record (reg.ru)      point a subdomain at this server
    8)  Firewall (ufw)             80/443/${SSH_PORT}/${BESZEL_PORT}, ${NODE_PORT} locked to the panel
    9)  Kernel tuning              BBR + fq, buffers, ICMP off, IPv6 switch
   10)  WARP                       warp-native, or reuse a wgcf profile
   11)  Beszel agent               install and enrol with the hub
   12)  SSH port -> ${SSH_PORT}            verified before port 22 is closed

   16)  Torrent guard              nftables: DHT, UDP trackers, BitTorrent ports
   17)  Speed shaper               >${SHAPE_TRIGGER_MBIT} Mbit/s for ${SHAPE_TRIGGER_SECONDS}s -> ${SHAPE_CAP_MBIT} Mbit/s
   18)  Guard status               counters, shaped clients, top talkers

   ${C_YEL}optional${C_RESET}
   13)  Zapret (DPI bypass)       download + run zapret's own installer
   14)  DPI check (test 4)        TCP 16-20KB blocking, before/after zapret
   15)  Find a strategy           zapret blockcheck, with zapret stopped first

    0)  Quit

MENU
}

menu() {
    local choice
    while :; do
        show_menu
        prompt "choose [0-18]: "
        read -r choice < /dev/tty || true
        case "${choice// /}" in
            1)  run_all; return 0 ;;
            2)  need_domain; install_docker
                locate_certs || true; install_remnanode; action_done ;;
            3)  need_domain; locate_certs || true
                if [[ -z "$CERT_PATH" ]]; then
                    warn "no certificate found for $NODE_DOMAIN — run selfsteal (4) first"
                else
                    install_remnanode; install_cert_watcher || true
                fi
                action_done ;;
            4)  need_domain; install_docker; install_selfsteal || true
                configure_fallback_site || true; action_done ;;
            5)  configure_fallback_site || true; action_done ;;
            6)  need_panel; need_domain; need_node_name
                resolve_config_profile; register_node; action_done ;;
            7)  MANAGE_DNS=yes; need_regru; setup_dns || true; await_dns || true; action_done ;;
            8)  need_panel; configure_ufw || true; action_done ;;
            9)  need_ipv6; tune_kernel || true; action_done ;;
           10)  install_warp || true; action_done ;;
           11)  need_domain; need_beszel; beszel_login || true
                install_beszel || true; action_done ;;
           12)  migrate_ssh || true; action_done ;;
           13)  run_dpi_check before || true
                install_zapret || true
                if systemctl is-active --quiet zapret 2>/dev/null; then
                    info "re-checking with zapret active"
                    run_dpi_check after || true
                fi
                action_done ;;
           14)  run_dpi_check manual || true; action_done ;;
           15)  run_blockcheck || true; action_done ;;
           16)  install_torrent_guard || true; action_done ;;
           17)  install_speed_shaper  || true; action_done ;;
           18)  guard_status || true; action_done ;;
            0|q|quit|exit) printf '
'; return 0 ;;
            "") ;;
            *)  warn "no such option: $choice" ;;
        esac
    done
}

main() {
    # Before the log redirect, so --help and bad arguments work without root.
    parse_args "$@"

    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
    printf '%s
' "=== install-node.sh $(date -Is) ===" >> "$LOG_FILE"

    preflight

    # No arguments and a terminal to talk to: show the menu. Any argument means
    # you already know what you want, so run the lot.
    if [[ "$RUN_MODE" == "menu" ]] || { [[ -z "$RUN_MODE" ]] && (( $# == 0 )) && [[ -r /dev/tty ]]; }; then
        menu
    else
        run_all
    fi
}

main "$@"
