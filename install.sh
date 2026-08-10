#!/usr/bin/env bash
#
# syno-letsencrypt installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/install.sh | sudo bash
#
# or, from a checkout:
#
#   sudo ./install.sh
#
# Downloads what it needs, asks a few questions, proves your Cloudflare token
# actually works before changing anything, and schedules a daily renewal.
#
# Re-running is safe: previous answers become the defaults, and an existing
# certificate is left alone.
#
set -euo pipefail

readonly REPO="ZenixSolutions/syno-letsencrypt"
REF="${SYNOLE_REF:-main}"
LEGO_VERSION="${LEGO_VERSION:-4.35.2}"
JQ_VERSION="${JQ_VERSION:-1.8.1}"

readonly BIN_DIR="/usr/local/bin"
readonly LIB_DIR="/usr/local/share/syno-letsencrypt/lib"
readonly CONFIG_DIR="/usr/local/etc/syno-letsencrypt"
readonly CONFIG="${CONFIG_DIR}/config"
readonly SYSTEMD_DIR="/etc/systemd/system"

# When piped from curl, stdin is the script itself — every prompt has to read
# from the terminal explicitly or it silently reads script text and races off.
TTY="/dev/tty"

SRC_DIR=""        # where the source tree lives, downloaded or local
CLEANUP_DIR=""
cleanup() { [ -n "${CLEANUP_DIR}" ] && rm -rf "${CLEANUP_DIR}"; }
trap cleanup EXIT

# --------------------------------------------------------------------------
# Presentation
# --------------------------------------------------------------------------
if [ -t 1 ] || [ -w "${TTY}" ] 2>/dev/null; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_BLUE=$'\033[38;5;39m'; C_GREEN=$'\033[38;5;42m'
    C_RED=$'\033[38;5;203m'; C_YELLOW=$'\033[38;5;221m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_BLUE=""; C_GREEN=""; C_RED=""; C_YELLOW=""
fi

say()   { printf '%s\n' "$*"; }
bold()  { printf '%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }
dim()   { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
ok()    { printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()  { printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*"; }
rule()  { printf '%s%s%s\n' "${C_DIM}" "──────────────────────────────────────────────────────────────" "${C_RESET}"; }
die()   { printf '\n%sError:%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2; exit 1; }

banner() {
    printf '%s' "${C_BLUE}"
    cat <<'ART'

   ███████╗███████╗███╗   ██╗██╗██╗  ██╗
   ╚══███╔╝██╔════╝████╗  ██║██║╚██╗██╔╝
     ███╔╝ █████╗  ██╔██╗ ██║██║ ╚███╔╝
    ███╔╝  ██╔══╝  ██║╚██╗██║██║ ██╔██╗
   ███████╗███████╗██║ ╚████║██║██╔╝ ██╗
   ╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝
ART
    printf '%s' "${C_RESET}"
    printf '   %sS O L U T I O N S%s\n\n' "${C_DIM}" "${C_RESET}"
    bold "   Let's Encrypt for Synology DSM"
    dim  "   Wildcard certificates over Cloudflare DNS-01. No open ports."
    say ""
}

# --------------------------------------------------------------------------
# Prompts — all read from the terminal, never stdin
# --------------------------------------------------------------------------
ask() {
    local prompt="$1" default="$2" __var="$3" reply=""
    while :; do
        if [ -n "${default}" ]; then
            printf '%s %s[%s]%s: ' "${prompt}" "${C_DIM}" "${default}" "${C_RESET}" > "${TTY}"
        else
            printf '%s: ' "${prompt}" > "${TTY}"
        fi
        IFS= read -r reply < "${TTY}" || die "No terminal available for input."
        reply="${reply:-${default}}"
        [ -n "${reply}" ] && break
        printf '  (required)\n' > "${TTY}"
    done
    printf -v "${__var}" '%s' "${reply}"
}

ask_secret() {
    local prompt="$1" __var="$2" reply=""
    while :; do
        printf '%s: ' "${prompt}" > "${TTY}"
        IFS= read -r -s reply < "${TTY}" || die "No terminal available for input."
        printf '\n' > "${TTY}"
        [ -n "${reply}" ] && break
        printf '  (required)\n' > "${TTY}"
    done
    printf -v "${__var}" '%s' "${reply}"
}

# ask_yn <prompt> <y|n default> <varname> — sets varname to true/false
ask_yn() {
    local prompt="$1" default="$2" __var="$3" reply="" hint
    [ "${default}" = "y" ] && hint="Y/n" || hint="y/N"
    printf '%s %s[%s]%s: ' "${prompt}" "${C_DIM}" "${hint}" "${C_RESET}" > "${TTY}"
    IFS= read -r reply < "${TTY}" || die "No terminal available for input."
    reply="${reply:-${default}}"
    case "${reply}" in
        [Yy]*) printf -v "${__var}" 'true' ;;
        *)     printf -v "${__var}" 'false' ;;
    esac
}

pause_for() {
    printf '\n%sPress Enter to continue%s' "${C_DIM}" "${C_RESET}" > "${TTY}"
    IFS= read -r _ < "${TTY}" || true
    printf '\n' > "${TTY}"
}

# --------------------------------------------------------------------------
# Pre-flight
# --------------------------------------------------------------------------
preflight() {
    bold "Checking this system"
    rule

    [ "$(id -u)" -eq 0 ] \
        || die "This needs root. Re-run with: curl -fsSL https://raw.githubusercontent.com/${REPO}/${REF}/install.sh | sudo bash"
    ok "running as root"

    [ -e "${TTY}" ] \
        || die "No terminal available. This installer is interactive — run it from an SSH session."

    [ -d /usr/syno/etc/certificate/_archive ] \
        || die "This does not look like a Synology NAS running DSM 7."
    ok "DSM certificate store found"

    [ -x /usr/syno/bin/synowebapi ] \
        || die "/usr/syno/bin/synowebapi is missing. DSM 7.0 or later is required."
    ok "DSM certificate API available"

    command -v curl >/dev/null 2>&1 || die "curl is required but not installed."

    if curl --silent --show-error --fail --max-time 15 -o /dev/null \
            https://api.cloudflare.com/client/v4/; then
        ok "can reach Cloudflare"
    else
        die "Cannot reach api.cloudflare.com. Check this NAS's DNS and internet access."
    fi
    say ""
}

# --------------------------------------------------------------------------
# Source
# --------------------------------------------------------------------------
# The files the installer needs when there is no checkout. Deliberately a
# short explicit list fetched from raw.githubusercontent.com rather than a
# source tarball: codeload/archive endpoints are blocked by some corporate and
# ISP proxies, while raw file fetches go through the same CDN as the installer
# itself — if you could download this script, you can download these.
readonly SOURCE_FILES=(
    "src/lib/log.sh"
    "src/lib/cloudflare.sh"
    "src/lib/dsm.sh"
    "src/bin/syno-letsencrypt"
)

obtain_source() {
    local here
    here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

    # Running from a checkout — use it, so development needs no push.
    if [ -n "${here}" ] && [ -f "${here}/src/lib/cloudflare.sh" ]; then
        SRC_DIR="${here}"
        ok "using the local checkout at ${here}"
        say ""
        return
    fi

    bold "Downloading syno-letsencrypt (${REF})"
    rule
    CLEANUP_DIR="$(mktemp -d)"
    SRC_DIR="${CLEANUP_DIR}"

    local f url
    for f in "${SOURCE_FILES[@]}"; do
        url="https://raw.githubusercontent.com/${REPO}/${REF}/${f}"
        mkdir -p "${SRC_DIR}/$(dirname "${f}")"
        if ! curl -fsSL --max-time 30 -o "${SRC_DIR}/${f}" "${url}"; then
            say ""
            die "Could not download ${f} from github.com/${REPO} (ref ${REF}).
       If the repository is private, clone it and run ./install.sh instead."
        fi
        # A proxy or captive portal returning an HTML error page with HTTP 200
        # would otherwise be sourced as shell. Cheap sanity check.
        head -n1 "${SRC_DIR}/${f}" | grep -q '^#' \
            || die "${f} does not look like a shell script. Something is intercepting the download."
    done
    ok "downloaded ${#SOURCE_FILES[@]} files"
    say ""
}

install_jq() {
    if command -v jq >/dev/null 2>&1; then
        ok "jq present ($(command -v jq))"
        return
    fi
    local a
    case "$(uname -m)" in
        x86_64)  a="linux-amd64" ;;
        aarch64) a="linux-arm64" ;;
        armv7l)  a="linux-armhf" ;;
        *) die "No jq build available for $(uname -m)" ;;
    esac
    # DSM ships jq on some models but not all, so check rather than assume.
    curl -fsSL -o "${BIN_DIR}/jq" \
        "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${a}" \
        || die "Could not download jq."
    chmod 755 "${BIN_DIR}/jq"
    export PATH="${BIN_DIR}:${PATH}"
    ok "installed jq ${JQ_VERSION}"
}

install_lego() {
    if [ -x "${BIN_DIR}/lego" ]; then
        ok "lego present ($("${BIN_DIR}/lego" --version 2>/dev/null | head -1))"
        return
    fi
    local a
    case "$(uname -m)" in
        x86_64)    a="amd64" ;;
        aarch64)   a="arm64" ;;
        armv7l)    a="armv7" ;;
        i686|i386) a="386"   ;;
        *) die "Unsupported CPU architecture: $(uname -m)" ;;
    esac
    mkdir -p "${BIN_DIR}"
    curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${a}.tar.gz" \
        | tar -xz -C "${BIN_DIR}" lego \
        || die "Could not download lego."
    chown root:root "${BIN_DIR}/lego"
    chmod 755 "${BIN_DIR}/lego"
    ok "installed lego ${LEGO_VERSION} (${a})"
}

install_dependencies() {
    bold "Installing dependencies"
    rule
    install_jq
    install_lego
    say ""
}

# --------------------------------------------------------------------------
# Cloudflare instructions
# --------------------------------------------------------------------------
token_instructions() {
    bold "Cloudflare API token"
    rule
    cat <<TXT
This tool proves you own your domain by creating a temporary DNS record, so it
needs a token that can edit DNS for that one zone — nothing else.

  ${C_BOLD}1.${C_RESET} Open  ${C_BLUE}https://dash.cloudflare.com/profile/api-tokens${C_RESET}
  ${C_BOLD}2.${C_RESET} Create Token  →  "Edit zone DNS"  →  Use template
  ${C_BOLD}3.${C_RESET} ${C_YELLOW}Add a second permission row:${C_RESET}

         Zone   │   Zone   │   Read

     ${C_DIM}The template only grants Zone → DNS → Edit. Without Zone → Read the
     certificate cannot be issued, because the domain has to be resolved to a
     zone ID first. This is the step nearly everyone misses.${C_RESET}

  ${C_BOLD}4.${C_RESET} Zone Resources  →  Include  →  your domain
  ${C_BOLD}5.${C_RESET} Continue to summary  →  Create Token  →  copy the value

The token is stored in ${CONFIG}, readable only by root.

TXT
}

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
install_files() {
    mkdir -p "${LIB_DIR}" "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"
    install -m 644 -o root -g root "${SRC_DIR}"/src/lib/*.sh "${LIB_DIR}/"
    install -m 755 -o root -g root "${SRC_DIR}/src/bin/syno-letsencrypt" "${BIN_DIR}/syno-letsencrypt"
    ok "installed ${BIN_DIR}/syno-letsencrypt"
}

write_config() {
    local tmp; tmp="$(mktemp)"
    cat > "${tmp}" <<CONF
# syno-letsencrypt configuration. Written by install.sh; safe to edit by hand.
# Contains a Cloudflare API token, so this file is root-only (0600).

CLOUDFLARE_DNS_API_TOKEN="${CF_TOKEN}"

# Comma separated. A wildcard does not cover the apex, so list both.
DOMAINS="${DOMAINS_IN}"

# Where Let's Encrypt sends expiry warnings.
ACME_EMAIL="${EMAIL_IN}"

# Staging issues untrusted test certificates, with no rate limits.
STAGING="${STAGING_IN}"

# Make this DSM's default certificate.
SET_DEFAULT="${SET_DEFAULT_IN}"

# Renew when fewer than this many days remain.
RENEW_DAYS="30"

# lego resolves the zone apex through the system resolver, which breaks on
# networks running Pi-hole, AdGuard or split-horizon DNS. Used for the
# challenge lookup only.
DNS_RESOLVERS="1.1.1.1:53 8.8.8.8:53"
CONF
    install -m 600 -o root -g root "${tmp}" "${CONFIG}"
    rm -f "${tmp}"
    ok "wrote ${CONFIG} (root only)"
}

install_timer() {
    # A systemd timer rather than cron: DSM rewrites /etc/crontab and is fussy
    # about its exact formatting, whereas DSM 7 is systemd-based. Persistent
    # catches up a run missed while the NAS was off, and the randomised delay
    # keeps every NAS on earth from hitting Let's Encrypt at the same minute.
    cat > "${SYSTEMD_DIR}/syno-letsencrypt.service" <<'UNIT'
[Unit]
Description=Renew Let's Encrypt certificate via Cloudflare DNS-01
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/syno-letsencrypt renew
UNIT

    cat > "${SYSTEMD_DIR}/syno-letsencrypt.timer" <<'UNIT'
[Unit]
Description=Daily Let's Encrypt renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    chmod 644 "${SYSTEMD_DIR}/syno-letsencrypt".{service,timer}
    systemctl daemon-reload
    systemctl enable --now syno-letsencrypt.timer >/dev/null 2>&1 \
        || warn "Could not enable the timer; run: systemctl enable --now syno-letsencrypt.timer"
    ok "scheduled a daily renewal check"
}

# --------------------------------------------------------------------------
main() {
    banner
    preflight
    obtain_source

    # shellcheck source=src/lib/log.sh
    . "${SRC_DIR}/src/lib/log.sh"
    # shellcheck source=src/lib/cloudflare.sh
    . "${SRC_DIR}/src/lib/cloudflare.sh"

    install_dependencies

    local CF_TOKEN="" DOMAINS_IN="" EMAIL_IN="" STAGING_IN="" SET_DEFAULT_IN=""
    local old_domains="" old_email=""
    if [ -r "${CONFIG}" ]; then
        # shellcheck disable=SC1090
        . "${CONFIG}"
        old_domains="${DOMAINS:-}"; old_email="${ACME_EMAIL:-}"
        warn "existing configuration found — press Enter at a prompt to keep the current value"
        say ""
    fi

    token_instructions
    pause_for
    ask_secret "Paste your Cloudflare API token" CF_TOKEN
    say ""

    bold "Certificate"
    rule
    dim "A wildcard covers sub.example.com but NOT example.com itself, so list both."
    ask "Domains (comma separated)" "${old_domains:-example.com,*.example.com}" DOMAINS_IN
    ask "Email for expiry notices" "${old_email}" EMAIL_IN
    say ""

    bold "Options"
    rule
    dim "Staging issues an untrusted TEST certificate with no rate limits. Production"
    dim "allows only 5 duplicate certificates per week, so it is worth one dry run."
    ask_yn "Use the Let's Encrypt staging environment first?" y STAGING_IN
    ask_yn "Make this DSM's default certificate?" y SET_DEFAULT_IN
    say ""

    # Validate before touching anything. A token that cannot do the job should
    # fail here with a specific reason, not in sixty days at three in the morning.
    bold "Verifying your Cloudflare token"
    rule
    local first="${DOMAINS_IN%%,*}"; first="${first# }"; first="${first#\*.}"
    if ! cf_check_token "${CF_TOKEN}" "${first}" >/dev/null; then
        say ""
        fail "That token cannot do what is needed. Nothing has been changed."
        die "Fix the permissions above and run the installer again."
    fi
    ok "token verified against ${first}"
    say ""

    bold "Installing"
    rule
    install_files
    write_config
    install_timer
    say ""

    rule
    bold "Done."
    rule
    say ""
    local confirm_issue
    ask_yn "Issue your certificate now?" y confirm_issue
    say ""

    if [ "${confirm_issue}" = "true" ]; then
        if "${BIN_DIR}/syno-letsencrypt" issue; then
            say ""
            ok "Certificate issued and installed into DSM."
            if [ "${STAGING_IN}" = "true" ]; then
                say ""
                warn "That was a STAGING certificate — browsers will not trust it."
                say  "     When you are happy, switch to the real one:"
                say  ""
                say  "         sudo sed -i 's/STAGING=\"true\"/STAGING=\"false\"/' ${CONFIG}"
                say  "         sudo syno-letsencrypt issue"
            fi
        else
            say ""
            fail "Issuance failed. Nothing else was changed; fix the above and run:"
            say  "     sudo syno-letsencrypt issue"
        fi
    else
        say "When you are ready:  sudo syno-letsencrypt issue"
    fi

    say ""
    dim "  sudo syno-letsencrypt status    expiry and next scheduled run"
    dim "  sudo syno-letsencrypt check     re-validate the token, change nothing"
    dim "  sudo syno-letsencrypt renew     what the daily timer runs"
    say ""
}

main "$@"
