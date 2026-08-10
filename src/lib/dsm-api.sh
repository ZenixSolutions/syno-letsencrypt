#!/usr/bin/env bash
# dsm-api.sh — install a certificate into DSM over its authenticated Web API.
#
# Why this and not the filesystem
# -------------------------------
# On DSM 7.3 nothing unprivileged can touch the certificate store: it is not
# readable, and synowebapi/synow3tool are mode-gated to root. A package cannot
# get root (the installer refuses it), and a container that mounts the store
# can write files but cannot make nginx reload them.
#
# This endpoint is the same one Control Panel uses when you upload a
# certificate by hand. DSM performs the privileged half itself — archive
# write, per-service copies, INFO/DEFAULT bookkeeping, web server reload — so
# we need no host access at all.
#
# Cost: a DSM account with administrator rights. Use a dedicated one that does
# nothing else. See docs/dsm-account.md.
#
# Requires: curl, jq. Assumes log.sh is loaded.

DSM_SID=""
DSM_TOKEN=""
DSM_AUTH_PATH="auth.cgi"

# _dsm_url <cgi> — DSM_URL is e.g. http://172.17.0.1:5000
_dsm_url() { printf '%s/webapi/%s' "${DSM_URL%/}" "$1"; }

_dsm_curl() {
    local -a args=(--silent --show-error --max-time 45)
    [ "${DSM_INSECURE:-false}" = "true" ] && args+=(--insecure)
    curl "${args[@]}" "$@"
}

# dsm_login — authenticate and populate DSM_SID / DSM_TOKEN.
dsm_login() {
    local out code version

    [ -n "${DSM_URL:-}" ]      || die "DSM_URL is not set."
    [ -n "${DSM_USERNAME:-}" ] || die "DSM_USERNAME is not set."
    [ -n "${DSM_PASSWORD:-}" ] || die "DSM_PASSWORD is not set."

    # Ask DSM where its auth endpoint lives and which version it speaks, rather
    # than hardcoding. Synology has moved both between releases.
    if out="$(_dsm_curl "$(_dsm_url query.cgi)?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth" 2>&1)"; then
        DSM_AUTH_PATH="$(printf '%s' "${out}" | jq -r '.data."SYNO.API.Auth".path // "auth.cgi"')"
        version="$(printf '%s' "${out}" | jq -r '.data."SYNO.API.Auth".maxVersion // 6')"
    else
        log_warn "Could not query DSM API info; falling back to auth.cgi v6."
        version=6
    fi
    log_debug "DSM auth endpoint=${DSM_AUTH_PATH} version=${version}"

    local url
    url="$(_dsm_url "${DSM_AUTH_PATH}")?api=SYNO.API.Auth&version=${version}&method=login&format=sid&enable_syno_token=yes"

    # Credentials go in the POST body, never the query string — a URL with a
    # password in it ends up in proxy and access logs.
    out="$(_dsm_curl --request POST --data-urlencode "account=${DSM_USERNAME}" \
            --data-urlencode "passwd=${DSM_PASSWORD}" \
            ${DSM_OTP_CODE:+--data-urlencode "otp_code=${DSM_OTP_CODE}"} \
            --data-urlencode "enable_device_token=yes" \
            ${DSM_DEVICE_NAME:+--data-urlencode "device_name=${DSM_DEVICE_NAME}"} \
            ${DSM_DEVICE_ID:+--data-urlencode "device_id=${DSM_DEVICE_ID}"} \
            "${url}" 2>&1)" || die "Could not reach DSM at ${DSM_URL}"

    if printf '%s' "${out}" | jq -e '.success == true' >/dev/null 2>&1; then
        DSM_SID="$(printf '%s' "${out}" | jq -r '.data.sid')"
        DSM_TOKEN="$(printf '%s' "${out}" | jq -r '.data.synotoken // empty')"

        # A device id lets subsequent logins skip the OTP. Surface it so the
        # operator can persist it and stop supplying codes.
        local did
        did="$(printf '%s' "${out}" | jq -r '.data.did // empty')"
        [ -n "${did}" ] && log_info "DSM issued a device id. Set DSM_DEVICE_ID=${did} to skip future OTP prompts."

        log_info "Authenticated to DSM as ${DSM_USERNAME}"
        return 0
    fi

    code="$(printf '%s' "${out}" | jq -r '.error.code // 0')"
    dsm_explain_login_error "${code}"
    return 1
}

dsm_explain_login_error() {
    case "$1" in
        400) log_error "DSM rejected the credentials. Check DSM_USERNAME and DSM_PASSWORD." ;;
        401) log_error "That DSM account is disabled." ;;
        402) log_error "That DSM account has no permission to sign in." ;;
        403) log_error "This DSM account has 2-factor authentication enabled."
             log_error "Unattended renewal cannot type a one-time code. Either turn 2FA off for"
             log_error "this dedicated account, or run once with DSM_OTP_CODE set and then keep"
             log_error "the DSM_DEVICE_ID it returns." ;;
        404) log_error "The one-time code was wrong." ;;
        406) log_error "2FA is enforced for this DSM account and it has not been set up yet." ;;
        407) log_error "DSM blocked this IP address. Check Control Panel > Security > Auto Block." ;;
        *)   log_error "DSM login failed (error ${1})." ;;
    esac
}

dsm_logout() {
    [ -n "${DSM_SID}" ] || return 0
    _dsm_curl --request POST \
        "$(_dsm_url "${DSM_AUTH_PATH}")?api=SYNO.API.Auth&version=1&method=logout&_sid=${DSM_SID}" \
        >/dev/null 2>&1 || true
    DSM_SID=""
}

# dsm_find_cert_id <description> — id of the certificate with this description.
dsm_find_cert_id() {
    local desc="$1" out
    out="$(_dsm_curl --request POST \
        --data "api=SYNO.Core.Certificate.CRT" --data "method=list" --data "version=1" \
        --data "_sid=${DSM_SID}" \
        ${DSM_TOKEN:+--header "X-SYNO-TOKEN: ${DSM_TOKEN}"} \
        "$(_dsm_url entry.cgi)" 2>&1)" || return 0

    if ! printf '%s' "${out}" | jq -e '.success == true' >/dev/null 2>&1; then
        # 105 here almost always means "not an administrator", which is the
        # single most common misconfiguration.
        if printf '%s' "${out}" | jq -e '.error.code == 105' >/dev/null 2>&1; then
            die "DSM account '${DSM_USERNAME}' is not an administrator. Certificate import requires it."
        fi
        return 0
    fi

    printf '%s' "${out}" | jq -r --arg d "${desc}" \
        '.data.certificates[]? | select(.desc == $d) | .id' | head -n1
}

# dsm_import_cert <cert.pem> <privkey.pem> <chain.pem> <description> <as_default>
#
# Replaces the certificate carrying the same description if one exists, so
# renewals update in place instead of adding a new entry every 60 days.
dsm_import_cert() {
    local cert="$1" key="$2" chain="$3" desc="$4" as_default="$5"
    local existing out

    for f in "${cert}" "${key}" "${chain}"; do
        [ -s "${f}" ] || die "Missing or empty certificate file: ${f}"
    done

    existing="$(dsm_find_cert_id "${desc}")"
    if [ -n "${existing}" ]; then
        log_info "Replacing DSM certificate '${desc}' (id ${existing})"
    else
        log_info "Importing new DSM certificate '${desc}'"
    fi

    local -a form=(
        --form "key=@${key}"
        --form "cert=@${cert}"
        --form "inter_cert=@${chain}"
        --form "desc=${desc}"
    )
    [ -n "${existing}" ]           && form+=(--form "id=${existing}")
    [ "${as_default}" = "true" ]   && form+=(--form "as_default=true")

    out="$(_dsm_curl --request POST "${form[@]}" \
        ${DSM_TOKEN:+--header "X-SYNO-TOKEN: ${DSM_TOKEN}"} \
        "$(_dsm_url entry.cgi)?api=SYNO.Core.Certificate&method=import&version=1&_sid=${DSM_SID}" 2>&1)" \
        || die "Certificate import request failed."

    if ! printf '%s' "${out}" | jq -e '.success == true' >/dev/null 2>&1; then
        die "DSM refused the certificate: $(dsm_explain_import_error "${out}")"
    fi

    log_info "DSM accepted the certificate."
    if printf '%s' "${out}" | jq -e '.data.restart_httpd == true' >/dev/null 2>&1; then
        log_info "DSM is restarting its web server; the UI may be briefly unavailable."
    fi
    return 0
}

dsm_explain_import_error() {
    local code
    code="$(printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null)"
    case "${code}" in
        105)  printf 'the account is not an administrator (105)' ;;
        5510) printf 'the certificate file was rejected as malformed (5510)' ;;
        5511) printf 'the private key was rejected as malformed (5511)' ;;
        5512) printf 'the intermediate certificate was rejected (5512)' ;;
        5513) printf 'the certificate chain is incomplete (5513)' ;;
        5514) printf 'the private key does not match the certificate (5514)' ;;
        '')   printf '%s' "$1" ;;
        *)    printf 'DSM error %s' "${code}" ;;
    esac
}
