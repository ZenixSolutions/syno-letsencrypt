#!/usr/bin/env bash
# dns.sh — reading public DNS without going through the local resolver.
#
# Why this exists
# ---------------
# A challenge record can be live and served correctly to the entire internet
# while the machine that created it cannot see it. Measured on a real NAS:
#
#   * lego created the TXT record and queried it two seconds later, before
#     Cloudflare was serving it;
#   * the resulting NXDOMAIN was cached for the zone's SOA minimum of 1800
#     seconds, so every later query returned the same stale negative;
#   * a sibling record created one second afterwards, never queried early,
#     resolved from that same NAS without trouble;
#   * queried from two other networks, both records resolved immediately.
#
# Port 53 was not blocked or intercepted — that theory was tested and rejected.
# The NAS resolved the zone's nameservers, its SOA, and other records in it
# perfectly. Only the one name that had been asked for too early was affected.
#
# What this file is for
# ---------------------
# DNS-over-HTTPS gives a view that a poisoned local cache cannot distort: a
# different resolver, reached over port 443, with no history of the name in
# question. That makes it the right tool for `check` and for diagnostics, where
# the question is "what does the rest of the world see?" rather than "what does
# this machine see?".
#
# It is deliberately NOT in the issuance path. lego cannot use DoH, and the fix
# for issuance is not to look harder — it is to not look at all until Let's
# Encrypt does, which is what --dns.propagation-wait achieves.

readonly DOH_ENDPOINT="${DOH_ENDPOINT:-https://cloudflare-dns.com/dns-query}"
readonly DOH_FALLBACK="${DOH_FALLBACK:-https://dns.google/resolve}"

# dns_doh_query <name> <type> — raw JSON answer, over HTTPS.
#
# Tries a second provider before giving up: if one is unreachable the answer is
# still obtainable, and using two independent operators means a single one
# cannot quietly become the only source of truth.
dns_doh_query() {
    local name="$1" type="$2" endpoint out

    for endpoint in "${DOH_ENDPOINT}" "${DOH_FALLBACK}"; do
        if out="$(curl -sS --max-time 15 \
                    -H 'accept: application/dns-json' \
                    "${endpoint}?name=${name}&type=${type}" 2>/dev/null)"; then
            # A captive portal or proxy returning HTML would otherwise be parsed
            # as an answer. Status is present in every real DoH JSON reply.
            if printf '%s' "${out}" | jq -e 'has("Status")' >/dev/null 2>&1; then
                printf '%s' "${out}"
                return 0
            fi
        fi
    done
    return 1
}

# dns_doh_txt <name> — TXT values, one per line.
#
# Exit 0 with no output means "asked successfully, nothing there" — distinct
# from exit 1, "could not ask". Callers need to tell those apart.
dns_doh_txt() {
    dns_doh_query "$1" TXT \
        | jq -r '.Answer[]? | select(.type == 16) | .data | gsub("^\"|\"$"; "")'
}

# dns_doh_ns <zone> — authoritative nameservers, from the public view.
dns_doh_ns() {
    dns_doh_query "$1" NS \
        | jq -r '.Answer[]? | select(.type == 2) | .data' | sed 's/\.$//'
}

# dns_local_ns <zone> — what this machine's own resolution path returns.
dns_local_ns() {
    nslookup -type=NS "$1" 2>/dev/null \
        | sed -n 's/.*nameserver = \(.*\)\.$/\1/p' | sort
}

# dns_check_public_visible <zone>
#
#   0  local port-53 resolution agrees with the public view
#   1  it does not — local answers for this zone are not the public truth
#   2  could not determine
#
# 1 and 2 are kept distinct deliberately. "I checked and they differ" and "I
# could not check" justify the same cautious behaviour but very different
# statements to the user, and collapsing them produces confident claims that
# nothing supports. Getting that wrong sent this project down a blind alley
# once already.
dns_check_public_visible() {
    local zone="$1" public local_ns

    public="$(dns_doh_ns "${zone}" | sort)" || return 2
    [ -n "${public}" ] || return 2

    command -v nslookup >/dev/null 2>&1 || return 2
    local_ns="$(dns_local_ns "${zone}")"
    [ -n "${local_ns}" ] || return 2

    if [ "${public}" = "${local_ns}" ]; then return 0; fi

    log_debug "public NS for ${zone}: $(printf '%s' "${public}" | tr '\n' ' ')"
    log_debug "local  NS for ${zone}: $(printf '%s' "${local_ns}" | tr '\n' ' ')"
    return 1
}

# dns_describe_view <zone> — the side-by-side comparison, for `check`.
dns_describe_view() {
    local zone="$1" l
    printf '  Public view of %s, over HTTPS:\n' "${zone}"
    dns_doh_ns "${zone}" | sed 's/^/    /' || printf '    <could not ask>\n'
    printf '  What this NAS resolves over port 53:\n'
    l="$(dns_local_ns "${zone}")"
    if [ -n "${l}" ]; then printf '%s\n' "${l}" | sed 's/^/    /'
    else printf '    <no answer>\n'; fi
}

# dns_wait_for_txt <name> <expected> <timeout_seconds>
#
# Waits for a TXT value to become visible in the public view, over HTTPS.
# Unused by the issuance path — lego owns that timing — but it is what makes an
# accurate propagation measurement possible on a network like this one.
dns_wait_for_txt() {
    local name="$1" expected="$2" timeout="${3:-180}"
    local start elapsed
    start="${SECONDS}"

    while :; do
        elapsed=$(( SECONDS - start ))
        if [ "${elapsed}" -ge "${timeout}" ]; then return 1; fi
        if dns_doh_txt "${name}" 2>/dev/null | grep -qF "${expected}"; then
            printf '%s' "${elapsed}"
            return 0
        fi
        sleep 5
    done
}
