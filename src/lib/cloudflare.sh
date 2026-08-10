#!/usr/bin/env bash
# cloudflare.sh — Cloudflare API v4 helpers.
#
# Responsibilities:
#   * Validate a user-supplied "bootstrap" token.
#   * Discover the zone that owns a given FQDN (API label walk, not DNS).
#   * Mint a least-privilege, zone-scoped token for ACME DNS-01.
#   * Self-test the minted token before it is trusted.
#
# This file is sourced, never executed. It assumes `log.sh` is already loaded.
#
# Design notes
# ------------
# Zone discovery deliberately uses the Cloudflare API label walk rather than
# lego's DNS SOA walk. lego resolves the zone apex by querying the system
# resolver, which fails on any network running Pi-hole, AdGuard, split-horizon
# DNS, or a router that hijacks port 53 — and it fails with an error that looks
# like a permissions problem. Doing our own API walk at install time means we
# fail loudly, at install, with an accurate message.
#
# Permission group IDs are resolved by NAME at runtime rather than hardcoded.
# User-owned and account-owned tokens are served by different endpoints, and it
# is not established that a group shared by both carries the same UUID. Name
# lookup costs one request and makes the question moot. The known-good IDs are
# retained only as a logged fallback.

CF_API="https://api.cloudflare.com/client/v4"

# Fallback permission group IDs. Corroborated by Cloudflare's own API docs
# sample, cert-manager, and the Cloudflare Terraform provider. Used only when
# the by-name lookup fails.
readonly CF_PG_DNS_WRITE_FALLBACK="4755a26eedb94da69e1066d98aa820be"
readonly CF_PG_ZONE_READ_FALLBACK="c8fed203ed3043cba015a93ad1616f1f"

# --------------------------------------------------------------------------
# Low-level request wrapper
# --------------------------------------------------------------------------

# cf_api <token> <method> <path> [json_body]
#
# Emits the raw response body on stdout. Returns non-zero and logs the
# Cloudflare error array if `success` is false or the transport failed.
cf_api() {
    local token="$1" method="$2" path="$3" body="${4:-}"
    local response http_code

    local -a curl_args=(
        --silent --show-error
        --max-time 30
        --retry 3 --retry-delay 2 --retry-connrefused
        --write-out '\n%{http_code}'
        --request "${method}"
        --header "Authorization: Bearer ${token}"
        --header "Content-Type: application/json"
    )
    [ -n "${body}" ] && curl_args+=(--data "${body}")

    if ! response="$(curl "${curl_args[@]}" "${CF_API}${path}" 2>&1)"; then
        log_error "Cloudflare request failed (${method} ${path}): ${response}"
        return 1
    fi

    http_code="${response##*$'\n'}"
    response="${response%$'\n'*}"

    if ! printf '%s' "${response}" | jq -e '.success == true' >/dev/null 2>&1; then
        log_error "Cloudflare API error (HTTP ${http_code}) on ${method} ${path}:"
        printf '%s' "${response}" \
            | jq -r '.errors[]? | "  [\(.code)] \(.message)"' >&2 2>/dev/null \
            || printf '  %s\n' "${response}" >&2
        return 1
    fi

    printf '%s' "${response}"
}

# --------------------------------------------------------------------------
# Bootstrap token pre-flight
# --------------------------------------------------------------------------

# cf_verify_token <token>
#
# Confirms the token exists and is active. Note this endpoint reports nothing
# about permissions — see cf_preflight_bootstrap for that.
cf_verify_token() {
    local token="$1" out status

    out="$(cf_api "${token}" GET /user/tokens/verify)" || return 1
    status="$(printf '%s' "${out}" | jq -r '.result.status')"

    case "${status}" in
        active) return 0 ;;
        expired)
            log_error "This Cloudflare token has expired. Create a new one."
            return 1 ;;
        disabled)
            log_error "This Cloudflare token is disabled. Re-enable it or create a new one."
            return 1 ;;
        *)
            log_error "Cloudflare token is in unexpected state: ${status}"
            return 1 ;;
    esac
}

# cf_preflight_bootstrap <token>
#
# Verifies the bootstrap token can actually mint tokens, BEFORE we try. Without
# this the user gets an opaque 403 in the middle of the install instead of an
# actionable message on the first screen.
#
# Introspection is a two-step: /verify yields our own token id (needs no
# permission), then GET /user/tokens/{id} yields the policy set (needs
# "API Tokens Read", which "API Tokens Write" implies — Write is full CRUDL).
cf_preflight_bootstrap() {
    local token="$1" out token_id policies

    cf_verify_token "${token}" || return 1

    out="$(cf_api "${token}" GET /user/tokens/verify)" || return 1
    token_id="$(printf '%s' "${out}" | jq -r '.result.id')"

    if ! out="$(cf_api "${token}" GET "/user/tokens/${token_id}")"; then
        log_error "Could not read this token's own permissions."
        log_error "The token needs the 'API Tokens' -> 'Edit' permission (User scope)."
        return 1
    fi

    policies="$(printf '%s' "${out}" \
        | jq -r '[.result.policies[]?.permission_groups[]?.name] | join(", ")')"

    if ! printf '%s' "${policies}" | grep -q 'API Tokens Write'; then
        log_error "This Cloudflare token cannot create other tokens."
        log_error "It currently grants: ${policies:-<none>}"
        log_error ""
        log_error "Create a token at https://dash.cloudflare.com/profile/api-tokens with:"
        log_error "    Permissions: User -> API Tokens -> Edit"
        log_error "That token is used ONCE during setup and is never stored."
        return 1
    fi

    log_debug "Bootstrap token validated (id=${token_id})"
    return 0
}

# --------------------------------------------------------------------------
# Zone discovery
# --------------------------------------------------------------------------

# cf_find_zone <token> <fqdn>
#
# Walks up the labels of <fqdn> asking Cloudflare which one is a zone, e.g.
# nas.home.example.com -> home.example.com -> example.com. Prints
# "<zone_id> <account_id> <zone_name>" on success.
#
# A name that is not a zone returns HTTP 200 with an empty result array, so the
# walk is safe to run against a narrowly-scoped token.
cf_find_zone() {
    local token="$1" fqdn="$2"
    local candidate="${fqdn#\*.}"   # a wildcard cert names the apex anyway
    local out count

    while [ -n "${candidate}" ] && [ "${candidate}" != "${candidate#*.}" ]; do
        log_debug "Looking up zone: ${candidate}"

        if out="$(cf_api "${token}" GET "/zones?name=${candidate}&per_page=50")"; then
            count="$(printf '%s' "${out}" | jq -r '.result | length')"

            if [ "${count}" -eq 1 ]; then
                printf '%s %s %s' \
                    "$(printf '%s' "${out}" | jq -r '.result[0].id')" \
                    "$(printf '%s' "${out}" | jq -r '.result[0].account.id')" \
                    "$(printf '%s' "${out}" | jq -r '.result[0].name')"
                return 0
            elif [ "${count}" -gt 1 ]; then
                log_error "Domain '${candidate}' matches ${count} zones across multiple"
                log_error "Cloudflare accounts. Specify the account explicitly."
                return 1
            fi
        fi

        candidate="${candidate#*.}"
    done

    log_error "No Cloudflare zone found for '${fqdn}'."
    log_error "Checked every parent domain up to the public suffix."
    log_error "Confirm the domain is in this Cloudflare account and the token can list zones."
    return 1
}

# --------------------------------------------------------------------------
# Token minting
# --------------------------------------------------------------------------

# cf_permission_group_id <token> <group_name> <fallback_id>
#
# Resolves a permission group name to its id. Cloudflare treats `name` as a
# filter rather than an exact key, so the result is re-filtered client-side and
# an ambiguous match is treated as an error — silently picking the wrong group
# would produce an over-privileged token.
cf_permission_group_id() {
    local token="$1" group_name="$2" fallback="$3"
    local out matches id

    if out="$(cf_api "${token}" GET \
        "/user/tokens/permission_groups?name=$(_urlencode "${group_name}")&per_page=100")"
    then
        matches="$(printf '%s' "${out}" \
            | jq --arg n "${group_name}" '[.result[] | select(.name == $n)]')"

        case "$(printf '%s' "${matches}" | jq 'length')" in
            1)
                id="$(printf '%s' "${matches}" | jq -r '.[0].id')"
                log_debug "Resolved permission group '${group_name}' -> ${id}"
                printf '%s' "${id}"
                return 0 ;;
            0) log_warn "Permission group '${group_name}' not found by name." ;;
            *) log_warn "Permission group '${group_name}' was ambiguous." ;;
        esac
    fi

    log_warn "Falling back to the known id for '${group_name}': ${fallback}"
    printf '%s' "${fallback}"
}

# cf_mint_token <bootstrap_token> <zone_id> <account_id> <token_name>
#
# Creates a user-owned token and prints its secret value.
#
# Policy shape is deliberately asymmetric:
#   * DNS Write  — pinned to the single zone. This is the permission that can
#                  actually do damage, so it gets the tight scope.
#   * Zone Read  — account-wide. lego's docs state zone listing needs account
#                  scope; a zone-scoped Zone Read has been observed returning
#                  `success: true` with an empty array, which lego surfaces
#                  weeks later as "zone could not be found" at renewal time.
#                  Zone Read discloses only zone names and metadata.
#
# cf_selftest_token below verifies this empirically rather than trusting it.
cf_mint_token() {
    local token="$1" zone_id="$2" account_id="$3" token_name="$4"
    local pg_dns pg_zone payload out

    pg_dns="$(cf_permission_group_id "${token}" "DNS Write" "${CF_PG_DNS_WRITE_FALLBACK}")"
    pg_zone="$(cf_permission_group_id "${token}" "Zone Read" "${CF_PG_ZONE_READ_FALLBACK}")"

    # No `condition.request.ip`: a NAS on a residential line has a dynamic
    # egress IP, so pinning it would silently break renewal on the next DHCP
    # lease. Zone scoping is the meaningful control here.
    #
    # No `expires_on`: an expiring token turns a working appliance into a
    # silently-broken one on a date nobody remembers. Rotation is explicit
    # (see cf_roll_token) rather than automatic.
    payload="$(jq -nc \
        --arg name "${token_name}" \
        --arg zone "com.cloudflare.api.account.zone.${zone_id}" \
        --arg acct "com.cloudflare.api.account.${account_id}" \
        --arg pg_dns "${pg_dns}" \
        --arg pg_zone "${pg_zone}" \
        '{
            name: $name,
            policies: [
                { effect: "allow",
                  resources: { ($zone): "*" },
                  permission_groups: [ { id: $pg_dns } ] },
                { effect: "allow",
                  resources: { ($acct): "*" },
                  permission_groups: [ { id: $pg_zone } ] }
            ]
        }')"

    out="$(cf_api "${token}" POST /user/tokens "${payload}")" || return 1

    # `result.value` is returned exactly once, at creation, and is never
    # retrievable again. The caller MUST persist it before doing anything else.
    printf '%s' "${out}" | jq -r '.result.value'
}

# cf_selftest_token <minted_token> <zone_id> <zone_name>
#
# Proves the minted token can do what lego will need, while the bootstrap token
# is still available to fix things. The dangerous case is not an error — it is
# HTTP 200 with an empty result array, which only surfaces as a failed renewal
# much later.
cf_selftest_token() {
    local token="$1" zone_id="$2" zone_name="$3"
    local out count found_id

    log_info "Verifying the new token can see zone '${zone_name}'..."

    if ! out="$(cf_api "${token}" GET "/zones?name=${zone_name}")"; then
        log_error "The new token could not list zones."
        return 1
    fi

    count="$(printf '%s' "${out}" | jq -r '.result | length')"
    if [ "${count}" -ne 1 ]; then
        log_error "Zone lookup with the new token returned ${count} results, expected 1."
        log_error "lego would fail later with 'zone could not be found'."
        return 1
    fi

    found_id="$(printf '%s' "${out}" | jq -r '.result[0].id')"
    if [ "${found_id}" != "${zone_id}" ]; then
        log_error "Zone id mismatch: expected ${zone_id}, got ${found_id}."
        return 1
    fi

    log_info "Verifying the new token can read DNS records..."
    if ! cf_api "${token}" GET "/zones/${zone_id}/dns_records?per_page=1" >/dev/null; then
        log_error "The new token cannot read DNS records for this zone."
        return 1
    fi

    log_info "Token self-test passed."
    return 0
}

# cf_revoke_token <bootstrap_token> <token_id>
#
# Used to clean up after a failed mint so we never leave orphaned credentials
# on the account.
cf_revoke_token() {
    local token="$1" token_id="$2"
    log_warn "Revoking Cloudflare token ${token_id}"
    cf_api "${token}" DELETE "/user/tokens/${token_id}" >/dev/null
}

# --------------------------------------------------------------------------

_urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}
