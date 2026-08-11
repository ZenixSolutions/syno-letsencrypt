#!/bin/sh
# Measure how long this Cloudflare zone actually takes to serve a new TXT
# record, on every one of its authoritative nameservers.
#
#   curl -fsSL https://raw.githubusercontent.com/ZenixSolutions/syno-letsencrypt/main/tools/diagnose-dns-poll.sh | sudo sh
#
# Creates two records and LEAVES THEM IN PLACE so they can be inspected in the
# Cloudflare dashboard. The delete commands are printed at the end.
#
# Why every nameserver: a Cloudflare zone has several, and lego polls until the
# record is visible on all of them. One lagging server is enough to fail the
# whole challenge while a spot check against a different one looks fine.

set -eu

CONFIG=/usr/local/etc/syno-letsencrypt/config
CF=https://api.cloudflare.com/client/v4
POLL_TIMEOUT="${POLL_TIMEOUT:-300}"     # seconds
POLL_INTERVAL="${POLL_INTERVAL:-5}"

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

hr
echo "Measuring propagation for: ${DOMAIN}"
echo "Polling every ${POLL_INTERVAL}s for up to ${POLL_TIMEOUT}s"
hr
echo

# ------------------------------------------------------------------- zone
ZONE_JSON="$(api GET "/zones?per_page=200")"
ZONE_ID="$(printf '%s' "${ZONE_JSON}" | jq -r --arg d "${DOMAIN}" '
    [ .result[] | . as $z | select(($d == $z.name) or ($d | endswith("." + $z.name))) ]
    | sort_by(.name|length) | if length==0 then empty else .[-1].id end')"
ZONE_NAME="$(printf '%s' "${ZONE_JSON}" | jq -r --arg d "${DOMAIN}" '
    [ .result[] | . as $z | select(($d == $z.name) or ($d | endswith("." + $z.name))) ]
    | sort_by(.name|length) | if length==0 then empty else .[-1].name end')"
echo "Zone: ${ZONE_NAME} (${ZONE_ID})"

# ------------------------------------------------- every authoritative server
NSLIST="$(nslookup -type=NS "${ZONE_NAME}" 1.1.1.1 2>/dev/null \
          | sed -n 's/.*nameserver = \(.*\)\.$/\1/p' | sort)"
if [ -z "${NSLIST}" ]; then
    echo "Could not list the zone's nameservers; falling back to 1.1.1.1 only."
    NSLIST="1.1.1.1"
fi
echo "Authoritative nameservers:"
printf '%s\n' "${NSLIST}" | sed 's/^/    /'
echo

# ------------------------------------------------------------ create records
SUB="_acme-challenge.${DOMAIN}"
APEX="_acme-challenge.${ZONE_NAME}"
STAMP="$(date +%s)"

create() {
    api POST "/zones/${ZONE_ID}/dns_records" \
        "$(jq -nc --arg n "$1" --arg c "$2" '{type:"TXT",name:$n,content:$c,ttl:120}')"
}

echo "Creating records..."
OUT1="$(create "${SUB}"  "poll-sub-${STAMP}")"
ID1="$(printf '%s' "${OUT1}" | jq -r '.result.id // empty')"
NAME1="$(printf '%s' "${OUT1}" | jq -r '.result.name // empty')"
echo "    ${SUB}"
echo "        id=${ID1:-FAILED}  stored as: ${NAME1:-?}"

OUT2="$(create "${APEX}" "poll-apex-${STAMP}")"
ID2="$(printf '%s' "${OUT2}" | jq -r '.result.id // empty')"
NAME2="$(printf '%s' "${OUT2}" | jq -r '.result.name // empty')"
echo "    ${APEX}"
echo "        id=${ID2:-FAILED}  stored as: ${NAME2:-?}"
if [ -z "${ID2}" ]; then
    echo "        error:"
    printf '%s' "${OUT2}" | jq -r '.errors[]? | "          [\(.code)] \(.message)"' 2>/dev/null
fi
echo
echo "Both records are being LEFT IN PLACE. Look for them in Cloudflare now."
echo

# ------------------------------------------------------------------- polling
# One line per (record, nameserver) pair, recording the first poll at which the
# record became visible. A pair that never resolves stays "never".
seen_sub=""
seen_apex=""
start="$(date +%s)"

resolves() {   # resolves <name> <server> <expected substring>
    nslookup -type=TXT "$1" "$2" 2>/dev/null | grep -q "$3"
}

hr
echo "Elapsed   record   nameserver                        result"
hr

while :; do
    now="$(date +%s)"
    elapsed=$(( now - start ))
    [ "${elapsed}" -gt "${POLL_TIMEOUT}" ] && break

    all_seen=1
    for ns in ${NSLIST}; do
        for which in sub apex; do
            case "${which}" in
                sub)  target="${SUB}";  want="poll-sub-${STAMP}"  ;;
                apex) target="${APEX}"; want="poll-apex-${STAMP}" ;;
                *) continue ;;
            esac

            # Already recorded as seen? skip.
            case "${which}" in
                sub)  printf '%s' "${seen_sub}"  | grep -q "|${ns}|" && continue ;;
                apex) printf '%s' "${seen_apex}" | grep -q "|${ns}|" && continue ;;
                *) ;;
            esac

            if resolves "${target}" "${ns}" "${want}"; then
                printf '%6ss   %-6s   %-32s  FOUND\n' "${elapsed}" "${which}" "${ns}"
                case "${which}" in
                    sub)  seen_sub="${seen_sub}|${ns}|"   ;;
                    apex) seen_apex="${seen_apex}|${ns}|" ;;
                    *) ;;
                esac
            else
                all_seen=0
            fi
        done
    done

    [ "${all_seen}" -eq 1 ] && { echo "All records visible on all nameservers."; break; }
    sleep "${POLL_INTERVAL}"
done

echo
hr
echo "Summary after ${elapsed}s"
hr
for ns in ${NSLIST}; do
    s="never"; a="never"
    printf '%s' "${seen_sub}"  | grep -q "|${ns}|" && s="seen"
    printf '%s' "${seen_apex}" | grep -q "|${ns}|" && a="seen"
    printf '  %-32s  %s=%-6s  %s=%s\n' "${ns}" "${SUB%%.*}" "${s}" "apex" "${a}"
done
echo
echo "Records left in place. To remove them when finished:"
[ -n "${ID1}" ] && echo "    sudo curl -sS -X DELETE ${CF}/zones/${ZONE_ID}/dns_records/${ID1} -H \"Authorization: Bearer \$CF_TOKEN\""
[ -n "${ID2}" ] && echo "    sudo curl -sS -X DELETE ${CF}/zones/${ZONE_ID}/dns_records/${ID2} -H \"Authorization: Bearer \$CF_TOKEN\""
echo
echo "  ...or just delete them in the Cloudflare dashboard, which is easier."
hr
