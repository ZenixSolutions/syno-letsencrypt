#!/usr/bin/env bash
# dns.sh — resolving DNS from a network that cannot be trusted to resolve it.
#
# The problem
# -----------
# On a NAS joined to Active Directory, the AD controller is usually
# authoritative for the same domain the public certificate is for — a
# split-horizon setup. Worse, many firewalls in those environments redirect all
# outbound port 53 to the internal resolver, so even an explicit query to
# 1.1.1.1 is answered by AD.
#
# That breaks DNS-01 validation in a way that looks like a Cloudflare problem:
# the challenge record is created correctly, but every local lookup returns
# NXDOMAIN because the internal zone has no such record and never will.
#
# lego cannot be configured around this. Its own documentation is explicit:
#
#     --dns.resolvers ... For DNS-01 challenge verification, the authoritative
#     DNS server is queried directly.
#
# So the resolver list only affects CNAME and apex lookups; the propagation
# check goes straight to the authoritative server and gets intercepted with
# everything else.
#
# The answer
# ----------
# Two mechanisms, neither of which uses port 53:
#
#   1. DNS-over-HTTPS to verify the record ourselves. Port 443, TLS, and the
#      response is authenticated by the certificate — it cannot be answered by
#      an internal resolver.
#
#   2. lego's --dns.propagation-wait, which skips its local checks entirely and
#      simply waits. Let's Encrypt then performs the only check that actually
#      matters, from the public internet, where the record is plainly visible.

readonly DOH_ENDPOINT="${DOH_ENDPOINT:-https://cloudflare-dns.com/dns-query}"
readonly DOH_FALLBACK="${DOH_FALLBACK:-https://dns.google/resolve}"

# dns_doh_txt <name> — TXT records for <name>, one per line, via DNS-over-HTTPS.
#
# Returns non-zero only on transport failure. A name that does not exist yields
# no output and exit 0, so callers can distinguish "not there yet" from
# "could not ask".
dns_doh_txt() {
    local name="$1" endpoint out

    for endpoint in "${DOH_ENDPOINT}" "${DOH_FALLBACK}"; do
        if out="$(curl -sS --max-time 15 \
                    -H 'accept: application/dns-json' \
                    "${endpoint}?name=${name}&type=TXT" 2>/dev/null)"; then
            if printf '%s' "${out}" | jq -e 'has("Status")' >/dev/null 2>&1; then
                printf '%s' "${out}" \
                    | jq -r '.Answer[]? | select(.type == 16) | .data | gsub("^\"|\"$"; "")'
                return 0
            fi
        fi
    done
    return 1
}

# dns_doh_ns <zone> — authoritative nameservers for <zone>, via DoH.
dns_doh_ns() {
    local zone="$1" out
    out="$(curl -sS --max-time 15 -H 'accept: application/dns-json' \
            "${DOH_ENDPOINT}?name=${zone}&type=NS" 2>/dev/null)" || return 1
    printf '%s' "${out}" | jq -r '.Answer[]? | select(.type == 2) | .data' | sed 's/\.$//'
}

# dns_local_ns <zone> — what this machine's own resolver believes.
dns_local_ns() {
    local zone="$1"
    nslookup -type=NS "${zone}" 2>/dev/null \
        | sed -n 's/.*nameserver = \(.*\)\.$/\1/p' | sort
}

# dns_check_split_horizon <zone>
#
#   0  local and public views agree — local propagation checks are trustworthy
#   1  they disagree — something other than the real authority answers locally
#   2  could not determine — no DoH answer, or no local resolver tool
#
# 1 and 2 are reported separately on purpose. "I checked and they differ" and
# "I could not check" warrant the same safe behaviour but very different
# messages, and conflating them produces confident statements that are not
# supported by anything.
dns_check_split_horizon() {
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

# dns_describe_split_horizon <zone> — human-readable comparison, for the
# installer and for `check`.
dns_describe_split_horizon() {
    local zone="$1"
    printf '  Public nameservers for %s (asked over HTTPS):\n' "${zone}"
    dns_doh_ns "${zone}" | sed 's/^/    /' || printf '    <could not ask>\n'
    printf '  This NAS resolves them as:\n'
    local l; l="$(dns_local_ns "${zone}")"
    if [ -n "${l}" ]; then printf '%s\n' "${l}" | sed 's/^/    /'
    else printf '    <no answer>\n'; fi
}
