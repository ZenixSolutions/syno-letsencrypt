#!/usr/bin/env bash
# dns.sh — reading public DNS from a network that intercepts port 53.
#
# The evidence
# ------------
# Measured on the target NAS. The same query, to the same public resolver, at
# the same moment:
#
#   From the NAS:
#     nslookup -type=TXT _acme-challenge.files.example.com 1.1.1.1
#     Server:  1.1.1.1
#     ** server can't find _acme-challenge.files.example.com: NXDOMAIN
#
#   From a machine on another network:
#     nslookup -type=TXT _acme-challenge.files.example.com 1.1.1.1
#     Server:  1.1.1.1
#     _acme-challenge.files.example.com  text = "poll-sub-1786416984"
#
# The record exists and Cloudflare serves it. The NAS addressed 1.1.1.1
# explicitly and still got NXDOMAIN, so its port-53 packets never reached
# 1.1.1.1 — something on the path answers them. Naming a different resolver
# does not help, because the destination address is not what is being honoured.
#
# Why this defeats lego on such a network
# ---------------------------------------
# lego must see the challenge record before it asks Let's Encrypt to validate.
# It queries over port 53, so it receives the intercepted answer and waits for a
# record that will never appear from its point of view. No timeout is long
# enough; the answer does not change.
#
# What actually works
# -------------------
# DNS-over-HTTPS. An ordinary HTTPS request on port 443, authenticated by TLS,
# which a port-53 redirect cannot touch and cannot forge. It is the only way
# this NAS can obtain a truthful public DNS answer.
#
# lego cannot be made to use it, so the division of labour is:
#   * this file  — establishes what public DNS really says, for `check`, for
#                  diagnostics, and for deciding whether local checks are
#                  trustworthy at all;
#   * lego       — told to skip its own checks via --dns.propagation-wait, with
#                  Let's Encrypt performing the verification that decides the
#                  outcome, from the public internet where the record is plainly
#                  visible.

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

    [ "${public}" = "${local_ns}" ] && return 0

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
        [ "${elapsed}" -ge "${timeout}" ] && return 1
        if dns_doh_txt "${name}" 2>/dev/null | grep -qF "${expected}"; then
            printf '%s' "${elapsed}"
            return 0
        fi
        sleep 5
    done
}
