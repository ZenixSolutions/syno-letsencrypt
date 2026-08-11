#!/usr/bin/env bash
# Isolate which parameter makes DSM's certificate import answer 5511.
#
#   curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/tools/probe-cert-replace.sh | sudo bash
#
# The question
# ------------
# probe-cert-import.sh succeeded on its first variant. zenix-cert fails on what
# looked like the same call. It is not the same call -- there are exactly three
# differences, and each was a separate guess of mine:
#
#   1. id=<cert>        replace in place rather than create
#   2. as_default=true  added when SET_DEFAULT="true"
#   3. the filename     mktemp writes /tmp/tmp.AbC123, which to anything
#                       checking extensions has the extension ".AbC123";
#                       the probe used /tmp/zprobe-key, with no dot at all
#
# So this changes ONE THING AT A TIME, starting from an exact reproduction of
# the failure. If V1 does not fail, the reproduction is wrong and nothing below
# it means anything -- which is why it runs first and says so.
#
# Uses the certificate already on disk. No ACME traffic.

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

# shellcheck disable=SC2154
DOMAIN="${DOMAINS%%,*}"; DOMAIN="${DOMAIN# }"; DOMAIN="${DOMAIN#\*.}"
BASE="${CONFIG_DIR}/lego/certificates/${DOMAIN}"
[ -f "${BASE}.crt" ] || BASE="${CONFIG_DIR}/lego/certificates/_.${DOMAIN}"

for f in "${BASE}.crt" "${BASE}.key" "${BASE}.issuer.crt"; do
    [ -s "${f}" ] || { echo "Missing or empty: ${f}"; exit 1; }
done

WORK="$(mktemp -d)"
LEAF="${WORK}/leaf"; KEY8="${WORK}/key8"
openssl x509 -in "${BASE}.crt" -out "${LEAF}" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "${BASE}.key" -out "${KEY8}" 2>/dev/null \
    || cp "${BASE}.key" "${KEY8}"

hdr "The certificate we are about to install"
printf 'Issuer:  %s\n' "$(openssl x509 -in "${LEAF}" -noout -issuer 2>/dev/null)"
printf 'Subject: %s\n' "$(openssl x509 -in "${LEAF}" -noout -subject 2>/dev/null)"
printf 'Expires: %s\n' "$(openssl x509 -in "${LEAF}" -noout -enddate 2>/dev/null)"

TARGET_ID="$(
    "${SYNOWEBAPI}" --exec-fastwebapi api=SYNO.Core.Certificate.CRT method=list version=1 2>/dev/null \
    | sed -n '/^[[:space:]]*{/,$p' \
    | jq -r --arg d "${DESC}" '.data.certificates[]? | select(.desc == $d) | .id' 2>/dev/null | head -n1
)"
printf 'Target:  %s\n' "${TARGET_ID:-<none>}"
if [ -z "${TARGET_ID}" ]; then
    echo
    echo "No certificate carries desc=\"${DESC}\", so there is nothing to replace"
    echo "and the id variants below cannot be tested. Run probe-cert-import.sh first."
    exit 1
fi

jstr() { printf '%s' "$1" | jq -Rs .; }

# try <label> <dotted_names> <send_id> <send_default>
#
# dotted_names=yes reproduces mktemp's /tmp/tmp.SUFFIX shape; no uses a plain
# name with no dot anywhere in it.
try() {
    local label="$1" dotted="$2" send_id="$3" send_default="$4"
    local k c i out rc stem

    hdr "${label}"

    # Reproduce mktemp's shape exactly -- "tmp." plus a random suffix and
    # nothing else -- rather than appending to it, since the whole question is
    # what the text after the dot looks like.
    rnd() { head -c5 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
    if [ "${dotted}" = yes ]; then
        k="/tmp/tmp.$(rnd)"; c="/tmp/tmp.$(rnd)"; i="/tmp/tmp.$(rnd)"
    else
        stem="/tmp/zprobe$$"; k="${stem}key"; c="${stem}crt"; i="${stem}chain"
    fi
    cp "${KEY8}" "${k}"; cp "${LEAF}" "${c}"; cp "${BASE}.issuer.crt" "${i}"
    chmod 600 "${k}" "${c}" "${i}"

    local -a args=(
        api=SYNO.Core.Certificate method=import version=1
        "key_tmp=$(jstr "${k}")"
        "cert_tmp=$(jstr "${c}")"
        "inter_cert_tmp=$(jstr "${i}")"
        "desc=$(jstr "${DESC}")"
    )
    [ "${send_id}" = yes ]      && args+=("id=$(jstr "${TARGET_ID}")")
    [ "${send_default}" = yes ] && args+=(as_default=true)

    printf '  filename shape : %s\n' "$([ "${dotted}" = yes ] && echo '/tmp/tmp.XXXXXX  (mktemp)' || echo '/tmp/zprobeNNN   (no dot)')"
    printf '  id=            : %s\n' "$([ "${send_id}" = yes ] && echo "${TARGET_ID}" || echo '(omitted)')"
    printf '  as_default=    : %s\n' "$([ "${send_default}" = yes ] && echo 'true' || echo '(omitted)')"

    printf '\n--- complete output, stderr included ---\n'
    out="$("${SYNOWEBAPI}" --exec-fastwebapi "${args[@]}" 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    printf -- '--- exit %s ---\n' "${rc}"

    rm -f "${k}" "${c}" "${i}"

    if printf '%s' "${out}" | sed -n '/^[[:space:]]*{/,$p' | jq -e '.success == true' >/dev/null 2>&1; then
        printf '\n>>> SUCCEEDED\n'
        return 0
    fi
    printf '\n>>> refused: %s\n' \
        "$(printf '%s' "${out}" | sed -n '/^[[:space:]]*{/,$p' | jq -r '.error.code // "?"' 2>/dev/null)"
    return 1
}

# --------------------------------------------------------------------------
# V1 must fail. It is exactly what zenix-cert sends. If it succeeds, the bug is
# not in these parameters at all and everything below is noise.
if try "V1  EXACT REPRODUCTION -- mktemp name, id, as_default" yes yes yes; then
    hdr "V1 SUCCEEDED -- the reproduction is wrong"
    cat <<'EOF'
This is the same call zenix-cert makes, and it worked. So the failure is not
in these three parameters, and it may not be deterministic. Nothing below
would have told us anything, so the probe stops here.

The certificate IS now installed. Send this output.
EOF
    rm -rf "${WORK}"; exit 0
fi

# One change from V1: as_default dropped.
if try "V2  drop as_default -- mktemp name, id" yes yes no; then
    hdr "ANSWER: as_default=true is what DSM rejects"
    echo "The certificate is installed and replaced in place, but is NOT the"
    echo "system default. Setting the default needs a separate call."
    rm -rf "${WORK}"; exit 0
fi

# One change from V1: filename shape.
if try "V3  drop the dot in the filename -- plain name, id, as_default" no yes yes; then
    hdr "ANSWER: the mktemp filename is what DSM rejects"
    echo "DSM reads /tmp/tmp.AbC123 as a file whose extension is '.AbC123'."
    echo "Fix is to name the temp files plainly. Certificate is installed."
    rm -rf "${WORK}"; exit 0
fi

# Both of the above at once, in case neither alone is sufficient.
if try "V4  plain name, id, no as_default" no yes no; then
    hdr "ANSWER: filename AND as_default together"
    echo "Neither change alone was enough; both were needed."
    rm -rf "${WORK}"; exit 0
fi

# The known-good shape from the previous probe, minus id entirely.
if try "V5  plain name, no id, no as_default  (known good last time)" no no no; then
    hdr "ANSWER: id= is what DSM rejects"
    cat <<'EOF'
Replace-in-place is not available to us through this API. A NEW certificate
entry has just been created rather than the existing one updated, so there
are now two carrying the same description -- expected, and the tool will need
to find and remove the stale one.

The default and the service assignments still need setting separately.
EOF
    rm -rf "${WORK}"; exit 0
fi

rm -rf "${WORK}"
hdr "Every variant refused"
cat <<'EOF'
Including V5, which succeeded twenty minutes ago with the staging certificate
and is unchanged. That points away from the parameters entirely and toward the
certificate itself -- the production chain differs from the staging one, and
inter_cert_tmp is the file that changed most between those two runs.

Send the full output.
EOF
exit 1
