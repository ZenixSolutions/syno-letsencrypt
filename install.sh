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

# --------------------------------------------------------------------------
# Animated checks
# --------------------------------------------------------------------------
# Each check is near-instant, so a spinner would flash past unread. Holding
# each one on screen briefly makes the sequence legible — the point is for
# someone to see what is being verified, not to save 12 seconds.

CHECK_DELAY="${CHECK_DELAY:-3}"          # seconds to show each check
# An array, not a string sliced with ${x:i:1}: bash substrings count bytes
# unless the locale is UTF-8, and a NAS shell is often not. Slicing the braille
# characters by byte emits fragments of multi-byte sequences rather than frames.
readonly SPIN_FRAMES=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
SPIN_TICK="0.08"

# DSM ships GNU sleep, but busybox sleep accepts whole seconds only. Probe once
# rather than assume, and fall back to a slower spin if fractions are refused.
_detect_sleep() {
    sleep 0.05 >/dev/null 2>&1 || SPIN_TICK="1"
}

# run_check <label> <command...>
#
# Runs the command with a spinner, then leaves a tick or a cross in place of it.
# Command output is shown only on failure, so a clean run stays clean.
run_check() {
    local label="$1"; shift
    local outfile rcfile rc pid frames=0 i=0 min_frames

    # No terminal (output redirected to a file, say) — just run it.
    if [ ! -t 1 ]; then
        if "$@" >/dev/null 2>&1; then ok "${label}"; return 0; fi
        fail "${label}"; return 1
    fi

    outfile="$(mktemp)"; rcfile="$(mktemp)"
    ( "$@" >"${outfile}" 2>&1; printf '%s' "$?" >"${rcfile}" ) &
    pid=$!

    if [ "${SPIN_TICK}" = "1" ]; then
        min_frames="${CHECK_DELAY}"
    else
        min_frames=$(( CHECK_DELAY * 12 ))
    fi

    while kill -0 "${pid}" 2>/dev/null || [ "${frames}" -lt "${min_frames}" ]; do
        printf '\r  %s%s%s %s' \
            "${C_BLUE}" "${SPIN_FRAMES[$(( i % ${#SPIN_FRAMES[@]} ))]}" "${C_RESET}" "${label}"
        i=$(( i + 1 )); frames=$(( frames + 1 ))
        sleep "${SPIN_TICK}"
    done
    wait "${pid}" 2>/dev/null || true

    rc="$(cat "${rcfile}" 2>/dev/null || echo 1)"
    printf '\r\033[2K'                       # erase the spinner line

    if [ "${rc}" = "0" ]; then
        ok "${label}"
        rm -f "${outfile}" "${rcfile}"
        return 0
    fi

    fail "${label}"
    if [ -s "${outfile}" ]; then
        while IFS= read -r l; do printf '      %s%s%s\n' "${C_DIM}" "${l}" "${C_RESET}"; done < "${outfile}"
    fi
    rm -f "${outfile}" "${rcfile}"
    return 1
}

banner() {
    local cols
    cols="$(tput cols 2>/dev/null || echo 80)"

    printf '%s' "${C_BLUE}"
    # The full wordmark is 100 columns. On anything narrower it wraps into
    # noise, so fall back to something that still reads as a logo.
    if [ "${cols}" -ge 104 ]; then
        cat <<'ART'
=====================
===================   **    *************  ************#    ***        ***    ***#   #***       #**#
====      =======   ****   #*************  *************    *****     ****#   ****   #*****    *****
====    =======   ******    #***********   *****#######*    ******    ****#   ****     ***** #****#
====  =======   *******          #****     *****            ********  ****#   ****      *********
==   ======   *******           *****      *************    ****#**** ****#   ****        ******
   ======   *******   **       ****        *************    ****  ********#   ****       ********
 ======   *******   ****     *****         *****            ****    ******#   ****     ***********
=====   *******    *****    *************  *************    ****     *****#   ****    *****   *****
===   *******      *****   **************  *************    ****      ****    ****   ****#      ****
=   ********************
  **********************
ART
    else
        cat <<'ART'

   ███████╗███████╗███╗   ██╗██╗██╗  ██╗
   ╚══███╔╝██╔════╝████╗  ██║██║╚██╗██╔╝
     ███╔╝ █████╗  ██╔██╗ ██║██║ ╚███╔╝
    ███╔╝  ██╔══╝  ██║╚██╗██║██║ ██╔██╗
   ███████╗███████╗██║ ╚████║██║██╔╝ ██╗
   ╚══════╝╚══════╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝
ART
    fi
    printf '%s\n' "${C_RESET}"
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
        if [ -n "${reply}" ]; then break; fi
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
        if [ -n "${reply}" ]; then break; fi
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
# Individual checks, each returning 0 or non-zero.

_check_root()      { [ "$(id -u)" -eq 0 ]; }
_check_tty()       { [ -e "${TTY}" ]; }
_check_store()     { [ -d /usr/syno/etc/certificate/_archive ]; }
_check_api()       { [ -x /usr/syno/bin/synowebapi ]; }
_check_curl()      { command -v curl >/dev/null 2>&1; }

# Reachability, not authorisation.
#
# An unauthenticated request to the Cloudflare API root correctly returns
# HTTP 400 ("Missing Authorization header"), and Let's Encrypt's directory
# returns 200. `curl --fail` treats any 4xx as an error, which made a perfectly
# healthy NAS look like it had no internet access. What matters here is whether
# an HTTP response came back at all: curl reports 000 when it could not connect.
_check_reachable() {
    local url="$1" code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${url}" 2>&1)" || code="000"
    case "${code}" in
        000|"") printf 'no HTTP response from %s\n' "${url}" >&2; return 1 ;;
        *)      return 0 ;;
    esac
}
_check_cloudflare()   { _check_reachable https://api.cloudflare.com/client/v4/; }
_check_letsencrypt()  { _check_reachable https://acme-v02.api.letsencrypt.org/directory; }

preflight() {
    bold "Checking this system"
    rule
    _detect_sleep

    run_check "running as root" _check_root \
        || die "This needs root. Re-run with: curl -fsSL https://raw.githubusercontent.com/${REPO}/${REF}/install.sh | sudo bash"

    run_check "interactive terminal available" _check_tty \
        || die "This installer is interactive. Run it from an SSH session."

    run_check "DSM certificate store found" _check_store \
        || die "This does not look like a Synology NAS running DSM 7."

    run_check "DSM certificate API available" _check_api \
        || die "/usr/syno/bin/synowebapi is missing. DSM 7.0 or later is required."

    run_check "curl available" _check_curl \
        || die "curl is required but not installed."

    run_check "Cloudflare reachable" _check_cloudflare \
        || die "Cannot reach api.cloudflare.com. Check this NAS's DNS and internet access."

    run_check "Let's Encrypt reachable" _check_letsencrypt \
        || die "Cannot reach acme-v02.api.letsencrypt.org. Check this NAS's DNS and internet access."

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
    "src/lib/schedule.sh"
    "src/lib/dns.sh"
    "src/lib/ui.sh"
    "src/bin/syno-letsencrypt"
    "docs/banner.txt"
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
        # would otherwise be sourced as shell. Cheap sanity check, skipped for
        # the ASCII wordmark, which is not a script.
        case "${f}" in
            *.sh|*/syno-letsencrypt)
                head -n1 "${SRC_DIR}/${f}" | grep -q '^#' \
                    || die "${f} does not look like a shell script. Something is intercepting the download."
                ;;
            *) ;;
        esac
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

     ${C_DIM}That template gives you one permission row:${C_RESET}

           Zone   ${C_DIM}(scope)${C_RESET}     DNS    ${C_DIM}(resource)${C_RESET}     Edit   ${C_DIM}(level)${C_RESET}

  ${C_BOLD}3.${C_RESET} ${C_YELLOW}Add a second row, and set the middle dropdown to "Zone":${C_RESET}

           Zone   ${C_DIM}(scope)${C_RESET}     ${C_YELLOW}Zone${C_RESET}   ${C_DIM}(resource)${C_RESET}     Read   ${C_DIM}(level)${C_RESET}

     ${C_DIM}Yes — "Zone" twice. The scope and the resource are both called Zone,
     which looks like a mistake but is not. This row is what lets the token
     look up which zone your domain belongs to; without it the certificate
     cannot be issued.

     Note it is NOT "Zone / DNS / Read" — that would be redundant, since the
     Edit level above already includes reading.${C_RESET}

  ${C_BOLD}4.${C_RESET} Zone Resources  →  Include  →  your domain
  ${C_BOLD}5.${C_RESET} Continue to summary  →  Create Token  →  copy the value

The token is stored in ${CONFIG}, readable only by root.

TXT
}

# --------------------------------------------------------------------------
# Which certificate, and which services
# --------------------------------------------------------------------------

# choose_certificate — sets CERT_MODE (replace|new) and CERT_REPLACE_ID.
#
# Replacing is the better default and not merely for tidiness: DSM preserves a
# certificate's entire service list when it is replaced in place, whereas a new
# entry starts with nothing attached. `as_default` does NOT migrate the other
# services — they stay on the old certificate — so a "new" certificate that
# looks right in Control Panel can leave FTPS, VPN and Drive still serving the
# old one.
choose_certificate() {
    bold "Certificate in DSM"
    rule

    local summary n=0
    local -a ids=() labels=()
    summary="$(dsm_cert_summary 2>/dev/null || true)"

    if [ -z "${summary}" ]; then
        warn "Could not read the existing certificates; a new one will be created."
        CERT_MODE="new"; CERT_REPLACE_ID=""
        say ""
        return
    fi

    say "This NAS currently has:"
    say ""
    while IFS=$'\t' read -r id desc cn isdef nsvc; do
        [ -n "${id}" ] || continue
        n=$((n + 1))
        ids+=("${id}")
        labels+=("${cn:-${desc:-${id}}}")
        printf '   %s%2d%s  %-38s %s%s, %s service(s)%s\n' \
            "${C_BOLD}" "${n}" "${C_RESET}" \
            "${cn:-${desc:-untitled}}" \
            "${C_DIM}" "${isdef:-not default}" "${nsvc}" "${C_RESET}"
    done <<< "${summary}"
    say ""

    dim "Replacing keeps every service the old certificate served."
    dim "Creating a new one starts with nothing attached, and you choose below."
    say ""

    local reply=""
    printf 'Replace one of these, or create a new certificate? %s[1-%d / new]%s: ' \
        "${C_DIM}" "${n}" "${C_RESET}" > "${TTY}"
    IFS= read -r reply < "${TTY}" || true
    reply="${reply:-1}"

    case "${reply}" in
        [Nn]*|"new")
            CERT_MODE="new"; CERT_REPLACE_ID=""
            ok "will create a new certificate"
            ;;
        *)
            if [ "${reply}" -ge 1 ] 2>/dev/null && [ "${reply}" -le "${n}" ]; then
                CERT_MODE="replace"
                CERT_REPLACE_ID="${ids[$((reply - 1))]}"
                ok "will replace: ${labels[$((reply - 1))]} (${CERT_REPLACE_ID})"
            else
                CERT_MODE="new"; CERT_REPLACE_ID=""
                warn "not a listed number — creating a new certificate instead"
            fi
            ;;
    esac
    say ""
}

# choose_services — writes the chosen service objects to services.json.
#
# The objects are stored verbatim as DSM reported them. Reassignment requires
# handing the same object back unchanged; the i18n keys and owner values differ
# per service and per DSM release, and inventing them is what produces the
# error 5503 people hit with this API.
choose_services() {
    bold "Which services should use this certificate?"
    rule

    local svcs count
    svcs="$(dsm_services_with_owner 2>/dev/null || printf '[]')"
    count="$(printf '%s' "${svcs}" | jq 'length' 2>/dev/null || echo 0)"

    if [ "${count}" -eq 0 ]; then
        warn "Could not read the service list; leaving assignments untouched."
        printf '[]' > "${CONFIG_DIR}/services.json"
        say ""
        return
    fi

    # Pre-select whatever the certificate being replaced already serves, so
    # pressing Enter is genuinely a no-op.
    local preselect="${CERT_REPLACE_ID:-}"
    local i=1
    local -a keys=() preset=()

    while IFS=$'\t' read -r name sub svc old; do
        keys+=("${sub}/${svc}")
        local mark="   "
        if [ -n "${preselect}" ] && [ "${old}" = "${preselect}" ]; then
            mark="${C_GREEN}[x]${C_RESET}"; preset+=("${i}")
        fi
        printf '   %s%2d%s %b %-38s %s%s%s\n' \
            "${C_BOLD}" "${i}" "${C_RESET}" "${mark}" "${name}" \
            "${C_DIM}" "$([ -n "${old}" ] && echo "currently: ${old}" || echo "unassigned")" "${C_RESET}"
        i=$((i + 1))
    done < <(printf '%s' "${svcs}" | jq -r '.[] | [ (.display_name // (.subscriber + "/" + .service)), .subscriber, .service, ._old_id ] | @tsv')

    say ""
    dim "Enter numbers separated by commas, or 'all', or 'none'."
    if [ ${#preset[@]} -gt 0 ]; then dim "Press Enter to keep the ones marked [x]."; fi
    say ""

    local reply=""
    printf 'Services %s[%s]%s: ' "${C_DIM}" \
        "$([ ${#preset[@]} -gt 0 ] && (IFS=,; echo "${preset[*]}") || echo "all")" "${C_RESET}" > "${TTY}"
    IFS= read -r reply < "${TTY}" || true

    if [ -z "${reply}" ]; then
        if [ ${#preset[@]} -gt 0 ]; then reply="$(IFS=,; echo "${preset[*]}")"; else reply="all"; fi
    fi

    local selected
    case "${reply}" in
        all|ALL|a)   selected="$(printf '%s' "${svcs}")" ;;
        none|NONE|n) selected='[]' ;;
        *)
            # Turn "1,3, 5" into a JSON array of zero-based indices.
            local idx
            idx="$(printf '%s' "${reply}" | tr ',' '\n' | tr -d ' ' \
                   | grep -E '^[0-9]+$' | awk '{ print $1 - 1 }' | jq -Rs 'split("\n") | map(select(length>0) | tonumber)')"
            selected="$(printf '%s' "${svcs}" | jq -c --argjson idx "${idx}" '[ . as $s | $idx[] | $s[.] | select(. != null) ]')"
            ;;
    esac

    printf '%s' "${selected}" > "${CONFIG_DIR}/services.json"
    chmod 0600 "${CONFIG_DIR}/services.json"
    ok "$(printf '%s' "${selected}" | jq 'length') service(s) selected"
    say ""
}

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
install_files() {
    mkdir -p "${LIB_DIR}" "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"
    install -m 644 -o root -g root "${SRC_DIR}"/src/lib/*.sh "${LIB_DIR}/"
    # The CLI draws the wordmark as a progress indicator while waiting for DNS.
    install -m 644 -o root -g root "${SRC_DIR}/docs/banner.txt" \
        /usr/local/share/syno-letsencrypt/banner.txt
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

# lego uses these instead of /etc/resolv.conf. Not sufficient on a network that
# intercepts port 53 — see PROPAGATION_MODE.
DNS_RESOLVERS="1.1.1.1:53 8.8.8.8:53"

# wait  = create the record, pause, and let Let's Encrypt do the verifying.
#         The certificate is still fully validated by the CA; only lego's own
#         local pre-check is skipped. This is the default because that
#         pre-check fails on any resolver holding a stale negative answer for
#         the challenge name -- see docs/architecture.md.
# check  = let lego confirm the record itself first. Cheaper when something is
#         genuinely wrong, since a failure costs a local timeout rather than
#         one of Let's Encrypt's five failed validations per hostname per hour.
PROPAGATION_MODE="wait"
PROPAGATION_WAIT="120"

# How DSM labels this certificate in Control Panel. Renewals match on it.
CERT_DESC="${CERT_DESC_IN}"

# replace = update an existing DSM certificate in place, keeping its services.
# new     = create a separate entry; services come from services.json.
CERT_MODE="${CERT_MODE}"
CERT_REPLACE_ID="${CERT_REPLACE_ID}"
CONF
    install -m 600 -o root -g root "${tmp}" "${CONFIG}"
    rm -f "${tmp}"
    ok "wrote ${CONFIG} (root only)"
}

# Earlier versions of this installer scheduled renewal with a systemd timer.
# Leaving it in place alongside the new DSM task would renew twice a day.
remove_legacy_timer() {
    [ -f /etc/systemd/system/syno-letsencrypt.timer ] || return 0
    systemctl disable --now syno-letsencrypt.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/syno-letsencrypt.timer \
          /etc/systemd/system/syno-letsencrypt.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "removed the systemd timer from a previous install"
}

install_schedule() {
    remove_legacy_timer
    # sched_install creates a root-owned daily task through synowebapi, since
    # synoschedtask has no --add. It prints the manual click-path and returns
    # non-zero if DSM refuses, rather than leaving renewal silently unscheduled.
    sched_install "${EMAIL_IN}" || true
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
    # shellcheck source=src/lib/dsm.sh
    . "${SRC_DIR}/src/lib/dsm.sh"
    # shellcheck source=src/lib/schedule.sh
    . "${SRC_DIR}/src/lib/schedule.sh"

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

    # Needs the tools in place first: the pickers read DSM state through jq.
    install_files

    local CERT_MODE="replace" CERT_REPLACE_ID="" CERT_DESC_IN=""
    CERT_DESC_IN="Let's Encrypt (${first})"
    choose_certificate
    choose_services

    bold "Installing"
    rule
    write_config
    install_schedule
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
    dim "  sudo syno-letsencrypt renew     what the scheduled task runs"
    say ""
    dim "  Renewal is visible in Control Panel > Task Scheduler."
    say ""
}

main "$@"
