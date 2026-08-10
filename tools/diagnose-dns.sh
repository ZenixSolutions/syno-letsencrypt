#!/bin/sh
# Diagnose why a DNS-01 challenge record is not visible to Let's Encrypt.
#
#   curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/tools/diagnose-dns.sh | sudo sh
#
# Reads the Cloudflare token from the installed config, creates one TXT record
# exactly as lego would, asks Cloudflare's own nameservers for it, and deletes
# it again. Everything it creates, it removes.

set -eu

CONFIG=/usr/local/etc/syno-letsencrypt/config
CF=https://api.cloudflare.com/client/v4

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -r "${CONFIG}" ] || { echo "No config at ${CONFIG}. Run the installer first."; exit 1; }

# DOMAINS and CLOUDFLARE_DNS_API_TOKEN come from the installed config.
# shellcheck disable=SC1090,SC2154
. "${CONFIG}"

# shellcheck disable=SC2154
DOMAIN="${DOMAINS%%,*}"
DOMAIN="${DOMAIN# }"
DOMAIN="${DOMAIN#\*.}"

# shellcheck disable=SC2154
api() {
    curl -sS --max-time 30 -X "$1" "${CF}$2" \
        -H "Authorization: Bearer ${CLOUDFLARE_DNS_API_TOKEN}" \
        -H "Content-Type: application/json" \
        ${3:+--data "$3"}
}

hr() { echo "===================================================================="; }

hr; echo "Domain under test: ${DOMAIN}"; hr; echo

# ---------------------------------------------------------------- zone
ZONE_JSON="$(api GET "/zones?per_page=200")"
ZONE_ID="$(printf '%s' "${ZONE_JSON}" | jq -r --arg d "${DOMAIN}" '
    [ .result[] | . as $z | select(($d == $z.name) or ($d | endswith("." + $z.name))) ]
    | sort_by(.name|length) | if length==0 then empty else .[-1].id end')"
ZONE_NAME="$(printf '%s' "${ZONE_JSON}" | jq -r --arg d "${DOMAIN}" '
    [ .result[] | . as $z | select(($d == $z.name) or ($d | endswith("." + $z.name))) ]
    | sort_by(.name|length) | if length==0 then empty else .[-1].name end')"

echo "Zone: ${ZONE_NAME} (${ZONE_ID})"
echo

# ------------------------------------------------- delegation beneath the zone
echo "1. NS records inside the zone (a delegation here would stop Cloudflare"
echo "   answering for anything beneath that name):"
api GET "/zones/${ZONE_ID}/dns_records?type=NS&per_page=100" \
  | jq -r '.result[]? | "     \(.name)  ->  \(.content)"' 2>/dev/null
echo "     (none listed above means no delegation)"
echo

# ------------------------------------------------------ leftover challenge TXT
echo "2. Existing _acme-challenge TXT records:"
api GET "/zones/${ZONE_ID}/dns_records?type=TXT&per_page=100" \
  | jq -r '.result[]? | select(.name | test("_acme-challenge")) | "     \(.name)  =  \(.content)"' 2>/dev/null
echo "     (none listed above means the zone is clean)"
echo

# ------------------------------------------------ what Cloudflare is asked for
NAME="_acme-challenge.${DOMAIN}"
APEX="_acme-challenge.${ZONE_NAME}"

echo "3. Creating a test TXT at: ${NAME}"
CREATE="$(api POST "/zones/${ZONE_ID}/dns_records" \
    "$(jq -nc --arg n "${NAME}" '{type:"TXT",name:$n,content:"zenix-dns-probe",ttl:120}')")"
REC_ID="$(printf '%s' "${CREATE}" | jq -r '.result.id // empty')"
if [ -z "${REC_ID}" ]; then
    echo "   FAILED to create:"
    printf '%s' "${CREATE}" | jq -r '.errors[]? | "     [\(.code)] \(.message)"' 2>/dev/null
else
    echo "   created id=${REC_ID}"
    echo "   Cloudflare says its full name is:"
    printf '%s' "${CREATE}" | jq -r '"     \(.result.name)"'
fi
echo

echo "4. Creating a second test TXT at the zone apex: ${APEX}"
CREATE2="$(api POST "/zones/${ZONE_ID}/dns_records" \
    "$(jq -nc --arg n "${APEX}" '{type:"TXT",name:$n,content:"zenix-dns-probe-apex",ttl:120}')")"
REC2_ID="$(printf '%s' "${CREATE2}" | jq -r '.result.id // empty')"
[ -n "${REC2_ID}" ] && echo "   created id=${REC2_ID}" || echo "   FAILED"
echo

echo "   waiting 20s for Cloudflare to serve them..."
sleep 20
echo

# ------------------------------------------------------------- authoritative
NS="$(nslookup -type=NS "${ZONE_NAME}" 1.1.1.1 2>/dev/null \
      | sed -n 's/.*nameserver = \(.*\)\.$/\1/p' | head -n1)"
echo "5. Authoritative nameserver for ${ZONE_NAME}: ${NS:-<could not determine>}"
echo

for target in "${NAME}" "${APEX}"; do
    echo "   --- ${target} ---"
    echo "   via 1.1.1.1:"
    nslookup -type=TXT "${target}" 1.1.1.1 2>&1 | sed -n '/text\|NXDOMAIN\|can.t find/p' | sed 's/^/     /'
    if [ -n "${NS}" ]; then
        echo "   via ${NS} (authoritative):"
        nslookup -type=TXT "${target}" "${NS}" 2>&1 | sed -n '/text\|NXDOMAIN\|can.t find/p' | sed 's/^/     /'
    fi
    echo
done

# ------------------------------------------------------------------- cleanup
echo "6. Removing the test records"
[ -n "${REC_ID}" ]  && { api DELETE "/zones/${ZONE_ID}/dns_records/${REC_ID}"  >/dev/null; echo "   removed ${REC_ID}"; }
[ -n "${REC2_ID}" ] && { api DELETE "/zones/${ZONE_ID}/dns_records/${REC2_ID}" >/dev/null; echo "   removed ${REC2_ID}"; }
echo
hr
echo "If the apex record resolved but the ${DOMAIN} one did not, the subdomain"
echo "is delegated away from Cloudflare and a certificate for it cannot be"
echo "validated this way. Issuing for the zone apex plus a wildcard avoids it."
hr
