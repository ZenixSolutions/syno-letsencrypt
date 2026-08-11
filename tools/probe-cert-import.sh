#!/usr/bin/env bash
# Exercise DSM's certificate import directly, to diagnose a rejected key.
#
#   curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/tools/probe-cert-import.sh | sudo bash
#
# Uses the certificate and key already present in the lego data directory, so
# it generates no ACME traffic and counts against no rate limit.
#
# What it does
# ------------
# Reports what lego wrote, whether the key and certificate actually pair, and
# whether DSM's web API shares this process's /tmp namespace. It then attempts
# the import four times, holding the key bytes constant and varying only how
# the files are presented: directory, filename extension, permissions, and
# replacing an existing certificate versus creating a new one.
#
# DSM's complete reply is printed for each attempt, including the stderr that
# the tool itself discards, since that output occasionally carries detail the
# error code does not.
#
# It stops at the first success. A successful import has installed the
# certificate for real, so this script changes state.
#
# Error 5511 is nominally "illegal key file" and does not reliably mean that.
# See docs/findings-dsm-cert-import.md for what has already been excluded.

set -u

CONFIG_DIR=/usr/local/etc/syno-letsencrypt
CONFIG="${CONFIG_DIR}/config"
SYNOWEBAPI=/usr/syno/bin/synowebapi

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -r "${CONFIG}" ]   || { echo "No config at ${CONFIG}."; exit 1; }
[ -x "${SYNOWEBAPI}" ] || { echo "No synowebapi. Is this DSM 7?"; exit 1; }

# shellcheck disable=SC1090
. "${CONFIG}"

hr() { printf '%s\n' '--------------------------------------------------------------------'; }
hdr() { printf '\n'; hr; printf '%s\n' "$1"; hr; }

# ------------------------------------------------------------------ the files
# shellcheck disable=SC2154
DOMAIN="${DOMAINS%%,*}"; DOMAIN="${DOMAIN# }"; DOMAIN="${DOMAIN#\*.}"
BASE="${CONFIG_DIR}/lego/certificates/${DOMAIN}"
[ -f "${BASE}.crt" ] || BASE="${CONFIG_DIR}/lego/certificates/_.${DOMAIN}"

SRC_CRT="${BASE}.crt"
SRC_KEY="${BASE}.key"
SRC_CHN="${BASE}.issuer.crt"

for f in "${SRC_CRT}" "${SRC_KEY}" "${SRC_CHN}"; do
    [ -s "${f}" ] || { echo "Missing or empty: ${f}"; exit 1; }
done

hdr "What lego actually wrote"
ls -l "${SRC_CRT}" "${SRC_KEY}" "${SRC_CHN}"
printf '\nKey first line: %s\n' "$(head -n1 "${SRC_KEY}")"
printf 'Key type:       %s\n' \
    "$(openssl pkey -in "${SRC_KEY}" -noout -text 2>/dev/null | head -n1)"
printf 'Cert subject:   %s\n' \
    "$(openssl x509 -in "${SRC_CRT}" -noout -subject 2>/dev/null)"

# A key that does not match its certificate is error 5514, not 5511, but it
# costs nothing to rule out and would explain a lot if it were true.
kmod="$(openssl pkey -in "${SRC_KEY}" -pubout 2>/dev/null | openssl sha256)"
cmod="$(openssl x509 -in "${SRC_CRT}" -noout -pubkey 2>/dev/null | openssl sha256)"
if [ "${kmod}" = "${cmod}" ]; then
    printf 'Key/cert pair:  MATCH\n'
else
    printf 'Key/cert pair:  MISMATCH  <-- this would be the whole problem\n'
    printf '  key  pubkey %s\n  cert pubkey %s\n' "${kmod}" "${cmod}"
fi

# Does the API process even share our /tmp? If DSM's webapi runs with a
# private tmp namespace, a path under /tmp is meaningless to it.
hdr "Is /tmp shared with DSM's web API?"
probe_marker="/tmp/zenix-tmp-probe-$$"
printf 'marker\n' > "${probe_marker}"
for p in $(pgrep -f 'synoscgi|nginx|synowebapi' 2>/dev/null | head -n 5); do
    if [ -r "/proc/${p}/mountinfo" ]; then
        if grep -qE '[[:space:]]/tmp[[:space:]]' "/proc/${p}/mountinfo" 2>/dev/null; then
            printf '  pid %-6s has its own /tmp mount  <-- private tmp\n' "${p}"
        else
            printf '  pid %-6s shares the global /tmp\n' "${p}"
        fi
    fi
done
rm -f "${probe_marker}"

# ------------------------------------------------------------- the candidates
# Same bytes every time. Only the location, name, and mode change.
WORK="$(mktemp -d)"
LEAF="${WORK}/leaf"; KEY8="${WORK}/key8"
openssl x509 -in "${SRC_CRT}" -out "${LEAF}" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "${SRC_KEY}" -out "${KEY8}" 2>/dev/null \
    || cp "${SRC_KEY}" "${KEY8}"

# Kept in its own variable: an apostrophe inside a ${VAR:-default} expansion is
# a parse error on older bash, and the NAS is not guaranteed to have a new one.
DEFAULT_DESC="Let's Encrypt (zenix-cert)"
DESC="${CERT_DESC:-${DEFAULT_DESC}}"

TARGET_ID="$(
    "${SYNOWEBAPI}" --exec-fastwebapi api=SYNO.Core.Certificate.CRT method=list version=1 2>/dev/null \
    | sed -n '/^[[:space:]]*{/,$p' \
    | jq -r --arg d "${DESC}" \
        '.data.certificates[]? | select(.desc == $d) | .id' 2>/dev/null | head -n1
)"
printf '\nReplacing DSM certificate id: %s\n' "${TARGET_ID:-<none found, will create new>}"

jstr() { printf '%s' "$1" | jq -Rs .; }

# try <label> <dir> <suffix> <mode> <use_id>
try() {
    local label="$1" dir="$2" suffix="$3" mode="$4" use_id="$5"
    local k c i out rc

    hdr "VARIANT: ${label}"

    mkdir -p "${dir}" 2>/dev/null
    chmod 755 "${dir}" 2>/dev/null
    k="${dir}/zprobe-key${suffix}"
    c="${dir}/zprobe-cert${suffix}"
    i="${dir}/zprobe-chain${suffix}"
    cp "${KEY8}" "${k}"; cp "${LEAF}" "${c}"; cp "${SRC_CHN}" "${i}"
    chmod "${mode}" "${k}" "${c}" "${i}"

    printf 'Files as DSM will find them:\n'
    ls -l "${k}" "${c}" "${i}" | sed 's/^/  /'

    local -a args=(
        api=SYNO.Core.Certificate method=import version=1
        "key_tmp=$(jstr "${k}")"
        "cert_tmp=$(jstr "${c}")"
        "inter_cert_tmp=$(jstr "${i}")"
        "desc=$(jstr "${DESC}")"
    )
    if [ "${use_id}" = yes ] && [ -n "${TARGET_ID}" ]; then
        args+=("id=$(jstr "${TARGET_ID}")")
    fi

    printf '\nsynowebapi --exec-fastwebapi \\\n'
    printf '    %s \\\n' "${args[@]}"

    printf '\n--- complete output, stderr included ---\n'
    out="$("${SYNOWEBAPI}" --exec-fastwebapi "${args[@]}" 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    # -- so printf does not read a format string beginning with "-" as options.
    printf -- '--- exit %s ---\n' "${rc}"

    rm -f "${k}" "${c}" "${i}"

    if printf '%s' "${out}" | sed -n '/^[[:space:]]*{/,$p' \
         | jq -e '.success == true' >/dev/null 2>&1; then
        printf '\n*** SUCCESS on variant: %s ***\n' "${label}"
        return 0
    fi
    return 1
}

# Ordered cheapest-explanation-first. Stops at the first success, because a
# success has installed the certificate for real and later variants would only
# reinstall it.
if try "A: /tmp, no extension, 0600  (what the tool does today)" \
       "/tmp" "" 600 yes; then exit 0; fi

if try "B: /tmp, .pem extension, 0644" \
       "/tmp" ".pem" 644 yes; then exit 0; fi

if try "C: config dir, .pem, 0644  (outside /tmp entirely)" \
       "${CONFIG_DIR}/import" ".pem" 644 yes; then exit 0; fi

if try "D: /tmp, .pem, 0644, no id  (create new instead of replace)" \
       "/tmp" ".pem" 644 no; then
    printf '\nNOTE: this created a NEW certificate entry rather than replacing.\n'
    printf 'Remove the duplicate in Control Panel > Security > Certificate.\n'
    exit 0
fi

rm -rf "${WORK}" "${CONFIG_DIR}/import"

hdr "All four variants refused"
cat <<'EOF'
Location, filename, permissions and replace-vs-create make no difference on
this system, which rules out how the files are presented.

On DSM 7.3-86009 the remaining known cause of this error is an argument
reaching the API with the wrong JSON type -- see
docs/findings-dsm-cert-import.md. If that has been excluded too, the next
thing to question is whether this DSM build expects the key inline rather
than as a file path.

Please include the full output above in any bug report.
EOF
exit 1
