#!/usr/bin/env bash
# Find out how to make a certificate the DSM system default.
#
#   curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/tools/probe-cert-default.sh | sudo bash
#
# What is already known
# ---------------------
# SYNO.Core.Certificate import refuses as_default=true with error 5511,
# "illegal key file" -- measured by changing that one parameter and nothing
# else. The same call without it succeeds and replaces the certificate in
# place.
#
# The leading theory is a type error, not a permission one. synowebapi parses
# every key=value argument as JSON, so as_default=true arrives as a JSON
# boolean. DSM may want the string "true". That is exactly the trap already
# documented in dsm.sh for certificate ids, where an id like 8ec29f37 is read
# as scientific notation unless it is quoted.
#
# If that is right the fix is one character and needs no second API call. So
# the string form is tested first, and the separate set-default endpoints are
# only tried if it fails.
#
# Changes nothing about which certificate is installed -- it is already in
# place. The only thing at stake is the is_default flag.

set -u

CONFIG_DIR=/usr/local/etc/syno-letsencrypt
CONFIG="${CONFIG_DIR}/config"
SYNOWEBAPI=/usr/syno/bin/synowebapi

[ "$(id -u)" -eq 0 ]   || { echo "Run with sudo."; exit 1; }
[ -r "${CONFIG}" ]     || { echo "No config at ${CONFIG}."; exit 1; }
[ -x "${SYNOWEBAPI}" ] || { echo "No synowebapi. Is this DSM 7?"; exit 1; }

# shellcheck disable=SC1090
. "${CONFIG}"

hr()  { printf '%s\n' '--------------------------------------------------------------------'; }
hdr() { printf '\n'; hr; printf '%s\n' "$1"; hr; }

DEFAULT_DESC="Let's Encrypt (zenix-cert)"
DESC="${CERT_DESC:-${DEFAULT_DESC}}"

jstr() { printf '%s' "$1" | jq -Rs .; }

api() { "${SYNOWEBAPI}" --exec-fastwebapi "$@" 2>&1; }
body() { printf '%s' "$1" | sed -n '/^[[:space:]]*{/,$p'; }
ok()   { body "$1" | jq -e '.success == true' >/dev/null 2>&1; }

certs() { body "$(api api=SYNO.Core.Certificate.CRT method=list version=1)"; }

show_state() {
    certs | jq -r '.data.certificates[]? |
        "  \(.id)  default=\(.is_default)  services=\((.services//[])|length)  desc=\(.desc)"'
}

hdr "Before"
show_state

ID="$(certs | jq -r --arg d "${DESC}" '.data.certificates[]? | select(.desc == $d) | .id' | head -n1)"
if [ -z "${ID}" ]; then
    echo; echo "No certificate carries desc=\"${DESC}\". Nothing to promote."; exit 1
fi
printf '\nPromoting: %s\n' "${ID}"

# The certificate and key are needed again only for the import-shaped attempts.
# shellcheck disable=SC2154
DOMAIN="${DOMAINS%%,*}"; DOMAIN="${DOMAIN# }"; DOMAIN="${DOMAIN#\*.}"
BASE="${CONFIG_DIR}/lego/certificates/${DOMAIN}"
[ -f "${BASE}.crt" ] || BASE="${CONFIG_DIR}/lego/certificates/_.${DOMAIN}"
WORK="$(mktemp -d)"
openssl x509 -in "${BASE}.crt" -out "${WORK}/c" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "${BASE}.key" -out "${WORK}/k" 2>/dev/null \
    || cp "${BASE}.key" "${WORK}/k"
cp "${BASE}.issuer.crt" "${WORK}/i"

# attempt <label> <arg>...
attempt() {
    local label="$1"; shift
    local out
    hdr "${label}"
    printf 'args: %s\n\n' "$*"
    out="$(api "$@")"
    printf '%s\n' "${out}"
    if ok "${out}"; then
        # success:true is not proof. This API family has reported success while
        # changing nothing before, so the flag is read back from a fresh list.
        if certs | jq -e --arg id "${ID}" \
             '.data.certificates[]? | select(.id == $id) | .is_default == true' >/dev/null 2>&1; then
            printf '\n>>> SUCCEEDED and is_default is now true\n'
            return 0
        fi
        printf '\n>>> reported success but is_default is still false -- not a fix\n'
        return 1
    fi
    printf '\n>>> refused: %s\n' "$(body "${out}" | jq -r '.error.code // "?"' 2>/dev/null)"
    return 1
}

# 1. The type theory: same import call, as_default as a JSON *string*.
if attempt "A  import with as_default=\"true\"  (string, not boolean)" \
    api=SYNO.Core.Certificate method=import version=1 \
    "key_tmp=$(jstr "${WORK}/k")" "cert_tmp=$(jstr "${WORK}/c")" \
    "inter_cert_tmp=$(jstr "${WORK}/i")" "desc=$(jstr "${DESC}")" \
    "id=$(jstr "${ID}")" 'as_default="true"'; then
    hdr "ANSWER: as_default must be a quoted string"
    echo "One-character fix in dsm.sh, no second API call needed. This is the"
    echo "same JSON-type trap already documented there for certificate ids."
    rm -rf "${WORK}"; show_state; exit 0
fi

# 2. A dedicated setter on the certificate API.
if attempt "B  SYNO.Core.Certificate method=set" \
    api=SYNO.Core.Certificate method=set version=1 "id=$(jstr "${ID}")" as_default=true; then
    hdr "ANSWER: set the default with a separate SYNO.Core.Certificate set call"
    rm -rf "${WORK}"; show_state; exit 0
fi

if attempt "C  SYNO.Core.Certificate method=set, as_default=\"true\"" \
    api=SYNO.Core.Certificate method=set version=1 "id=$(jstr "${ID}")" 'as_default="true"'; then
    hdr "ANSWER: separate set call, with as_default quoted"
    rm -rf "${WORK}"; show_state; exit 0
fi

# 3. The same idea on the CRT sub-API, which is what `list` lives on.
if attempt "D  SYNO.Core.Certificate.CRT method=set" \
    api=SYNO.Core.Certificate.CRT method=set version=1 "id=$(jstr "${ID}")" as_default=true; then
    hdr "ANSWER: SYNO.Core.Certificate.CRT set"
    rm -rf "${WORK}"; show_state; exit 0
fi

# 4. What the Control Panel button may actually send: the id under a different
#    parameter name entirely.
if attempt "E  CRT set with cert_id=" \
    api=SYNO.Core.Certificate.CRT method=set version=1 "cert_id=$(jstr "${ID}")" as_default=true; then
    hdr "ANSWER: CRT set, parameter named cert_id"
    rm -rf "${WORK}"; show_state; exit 0
fi

rm -rf "${WORK}"

hdr "None of them set the flag"
show_state
cat <<'EOF'

No harm done -- the certificate itself is untouched and still installed.

This is where a workaround earns its place rather than more guessing: the
tool will assign the services it was asked to, and setting the default
becomes a one-off click in Control Panel > Security > Certificate. The
default survives replace-in-place renewals, so it is genuinely a one-time
action rather than something that needs automating.

Send the full output.
EOF
exit 1
