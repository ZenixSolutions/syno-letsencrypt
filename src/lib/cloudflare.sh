#!/usr/bin/env bash
# cloudflare.sh — Cloudflare API v4 helpers.
#
# Responsibilities:
#   * Validate a user-supplied API token, functionally.
#   * Discover the zone that owns a given domain.
#
# Sourced, never executed. Assumes log.sh is already loaded.
#
# Why validation is functional rather than declarative
# ----------------------------------------------------
# A DNS-scoped token cannot introspect its own permissions. Reading
# /user/tokens/{id} requires "API Tokens Read", a User-scoped permission that a
# zone-scoped token does not have. So there is no way to ask "what can this
# token do?" — we have to try each thing lego will need and see.
#
# Why zone lookup is unfiltered
# -----------------------------
# GET /zones?name=<domain> is a trap. When the token lacks zone:list, or when
# the zone is outside its scope, Cloudflare returns HTTP 403 with error code
# literally 0 — indistinguishable from the user mistyping their domain. Listing
# all visible zones and matching locally separates those two cases, so we can
# tell someone "your token can't list zones" instead of "domain not found".

CF_API="https://api.cloudflare.com/client/v4"

# --------------------------------------------------------------------------
# Low-level request wrapper
# --------------------------------------------------------------------------

# cf_api <token> <method> <path> [json_body]
#
# Emits the response body on stdout. Returns non-zero and logs Cloudflare's
# error array when `success` is false or the transport failed.
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
        # Cloudflare temporarily locks out a token after several failed auth
        # attempts. Reporting that as "invalid token" would send someone off
        # regenerating a token that was fine all along.
        if printf '%s' "${response}" | jq -e '[.errors[]?.code] | any(. == 10502 or . == 10429)' \
                >/dev/null 2>&1; then
            log_error "Cloudflare is rate-limiting this token after repeated failures."
            log_error "Wait a few minutes and try again — the token itself may be fine."
            return 1
        fi

        log_error "Cloudflare API error (HTTP ${http_code}) on ${method} ${path}:"
        printf '%s' "${response}" \
            | jq -r '.errors[]? | "  [\(.code)] \(.message)"' >&2 2>/dev/null \
            || printf '  %s\n' "${response}" >&2
        return 1
    fi

    printf '%s' "${response}"
}

# --------------------------------------------------------------------------
# Zone discovery
# --------------------------------------------------------------------------

# cf_find_zone <token> <domain>
#
# Prints "<zone_id> <zone_name>". Lists every zone the token can see and
# matches the longest suffix of <domain>, so nas.home.example.com resolves to
# zone example.com without depending on local DNS.
cf_find_zone() {
    local token="$1" domain="${2#\*.}"
    local out match

    if ! out="$(cf_api "${token}" GET "/zones?per_page=200")"; then
        log_error "The token could not list zones."
        log_error "Add the 'Zone -> Zone -> Read' permission in Cloudflare."
        log_error "Note: Cloudflare's 'Edit zone DNS' template does NOT include it."
        return 1
    fi

    # Longest match wins, so a token that can see both example.com and
    # sub.example.com picks the more specific zone the record belongs to.
    match="$(printf '%s' "${out}" | jq -r --arg d "${domain}" '
        [ .result[]
          | select($d == .name or ($d | endswith("." + .name)))
        ] | sort_by(.name | length) | last // empty
        | "\(.id) \(.name)"')"

    if [ -z "${match}" ]; then
        log_error "No zone in this Cloudflare account matches '${domain}'."
        log_error "Zones this token can see:"
        printf '%s' "${out}" | jq -r '.result[]? | "  " + .name' >&2
        log_error "Check the domain spelling, and that the token's Zone Resources include it."
        return 1
    fi

    printf '%s' "${match}"
}

# --------------------------------------------------------------------------
# Token validation
# --------------------------------------------------------------------------

# cf_verify_token <token> — liveness only; says nothing about permissions.
cf_verify_token() {
    local token="$1" out status

    out="$(cf_api "${token}" GET /user/tokens/verify)" || return 1
    status="$(printf '%s' "${out}" | jq -r '.result.status')"

    case "${status}" in
        active)   return 0 ;;
        expired)  log_error "This Cloudflare token has expired. Create a new one."; return 1 ;;
        disabled) log_error "This Cloudflare token is disabled."; return 1 ;;
        *)        log_error "Cloudflare token is in an unexpected state: ${status}"; return 1 ;;
    esac
}

# cf_check_token <token> <domain>
#
# Full functional check. Prints "<zone_id> <zone_name>" on success.
cf_check_token() {
    local token="$1" domain="$2"
    local zone_info zone_id zone_name

    # Catch the two common paste mistakes locally, before spending an API call
    # and risking the auth-failure lockout.
    case "${token}" in
        cfk_*)
            log_error "That is a Cloudflare Global API Key, not an API token."
            log_error "A global key grants access to your whole account; create a scoped token instead."
            return 1 ;;
        *) ;;
    esac
    if [ "${#token}" -lt 40 ]; then
        log_error "That token is only ${#token} characters. Cloudflare tokens are at least 40."
        return 1
    fi

    log_info "Checking the Cloudflare token is active..."
    if ! cf_verify_token "${token}"; then
        # /user/tokens/verify accepts USER tokens only. An account-scoped token
        # is reported as invalid here even when it is perfectly good, so this
        # failure is not conclusive on its own.
        case "${token}" in
            cfat_*) log_warn "Account-scoped token; skipping the user-token check." ;;
            *)      return 1 ;;
        esac
    fi

    log_info "Looking up the zone for ${domain}..."
    zone_info="$(cf_find_zone "${token}" "${domain}")" || return 1
    read -r zone_id zone_name <<<"${zone_info}"
    log_info "Zone: ${zone_name} (${zone_id})"

    log_info "Checking the token can edit DNS records..."
    cf_test_dns_write "${token}" "${zone_id}" "${zone_name}" || return 1

    log_info "Cloudflare token has everything it needs."
    printf '%s %s' "${zone_id}" "${zone_name}"
}

# cf_test_dns_write <token> <zone_id> <zone_name>
#
# Cloudflare offers no dry-run and no permission introspection, so the only
# honest test of write access is to write. The record name is deliberately
# distinct from _acme-challenge so it can never collide with a challenge in
# flight, and it is removed immediately.
cf_test_dns_write() {
    local token="$1" zone_id="$2" zone_name="$3"
    local payload out record_id

    payload="$(jq -nc --arg n "_syno-letsencrypt-check.${zone_name}" \
        '{ type: "TXT", name: $n, content: "permission check - safe to delete", ttl: 120 }')"

    if ! out="$(cf_api "${token}" POST "/zones/${zone_id}/dns_records" "${payload}")"; then
        log_error "The token cannot create DNS records in ${zone_name}."
        log_error "Add the 'Zone -> DNS -> Edit' permission in Cloudflare."
        return 1
    fi

    record_id="$(printf '%s' "${out}" | jq -r '.result.id')"

    if ! cf_api "${token}" DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null; then
        log_warn "Created a test DNS record but could not remove it."
        log_warn "Delete _syno-letsencrypt-check.${zone_name} manually in Cloudflare."
    fi
    return 0
}
