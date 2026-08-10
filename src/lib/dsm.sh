#!/usr/bin/env bash
# dsm.sh — hand a certificate to DSM.
#
# Runs as root, so it uses `synowebapi --exec-fastwebapi`, which invokes DSM's
# own Web API in-process. That is the same code path Control Panel uses when you
# upload a certificate by hand, so DSM does all the fiddly parts itself:
# the _archive write, the copy to every subscribing service, the INFO/DEFAULT
# bookkeeping, and the web server reload.
#
# Deliberately NOT doing it by hand
# ---------------------------------
# Writing the PEM files directly is the traditional approach and it is now a
# trap. On DSM 7.3 `system/default` contains ECC-cert.pem and RSA-cert.pem —
# DSM installs an elliptic-curve and an RSA certificate side by side and serves
# whichever the client negotiates. The `cert.pem` / `privkey.pem` /
# `fullchain.pem` names that every filesystem-based tool writes no longer exist
# there. The layout is undocumented and it changed between releases, so we let
# DSM own it.
#
# Also deliberately not doing it: the HTTP Web API with a DSM administrator
# password. That is what acme.sh's deploy hook does, and it needs an admin
# credential on disk, breaks under 2FA, and its unattended workaround disables
# 2FA enforcement DSM-wide while it runs. Running as root, none of that is
# necessary.

readonly DSM_CERT_ARCHIVE="/usr/syno/etc/certificate/_archive"
readonly SYNOWEBAPI="/usr/syno/bin/synowebapi"

# dsm_require_root [subcommand] — the subcommand is only used to make the
# suggested sudo line copy-pasteable.
dsm_require_root() {
    [ "$(id -u)" -eq 0 ] || die "This must run as root. Try: sudo ${0##*/} ${1:-}"
}

dsm_preflight() {
    dsm_require_root ""
    [ -x "${SYNOWEBAPI}" ] \
        || die "${SYNOWEBAPI} not found. This does not look like DSM 7."
    [ -d "${DSM_CERT_ARCHIVE}" ] \
        || die "DSM certificate store not found at ${DSM_CERT_ARCHIVE}."
}

# dsm_find_cert_id <description> — id of the certificate with this description,
# or nothing. Used so a renewal replaces the existing entry instead of adding a
# new certificate to Control Panel every 60 days.
dsm_find_cert_id() {
    local desc="$1" out

    out="$("${SYNOWEBAPI}" --exec-fastwebapi \
        api=SYNO.Core.Certificate.CRT method=list version=1 2>/dev/null)" || return 0

    printf '%s' "${out}" \
        | jq -r --arg d "${desc}" \
            '.data.certificates[]? | select(.desc == $d) | .id' 2>/dev/null \
        | head -n1
}

# dsm_import_cert <cert.pem> <privkey.pem> <chain.pem> <description> <as_default>
dsm_import_cert() {
    local cert="$1" key="$2" chain="$3" desc="$4" as_default="$5"
    local existing out

    dsm_preflight

    local f
    for f in "${cert}" "${key}" "${chain}"; do
        [ -s "${f}" ] || die "Missing or empty certificate file: ${f}"
    done

    existing="$(dsm_find_cert_id "${desc}")"
    if [ -n "${existing}" ]; then
        log_info "Replacing DSM certificate '${desc}' (id ${existing})"
    else
        log_info "Importing new DSM certificate '${desc}'"
    fi

    local -a args=(
        --exec-fastwebapi
        api=SYNO.Core.Certificate method=import version=1
        "key_tmp=${key}"
        "cert_tmp=${cert}"
        "inter_cert_tmp=${chain}"
        "desc=${desc}"
    )
    [ -n "${existing}" ]         && args+=("id=${existing}")
    [ "${as_default}" = "true" ] && args+=("as_default=true")

    if ! out="$("${SYNOWEBAPI}" "${args[@]}" 2>&1)"; then
        die "synowebapi failed: $(dsm_explain_error "${out}")"
    fi

    if ! printf '%s' "${out}" | jq -e '.success == true' >/dev/null 2>&1; then
        die "DSM refused the certificate: $(dsm_explain_error "${out}")"
    fi

    log_info "DSM accepted the certificate."
    if printf '%s' "${out}" | jq -e '.data.restart_httpd == true' >/dev/null 2>&1; then
        log_info "DSM is restarting its web server; the UI may blip for a few seconds."
    fi
}

dsm_explain_error() {
    local code
    code="$(printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null)"
    case "${code}" in
        5510) printf 'the certificate file was rejected as malformed (5510)' ;;
        5511) printf 'the private key was rejected as malformed (5511)' ;;
        5512) printf 'the intermediate certificate was rejected (5512)' ;;
        5513) printf 'the certificate chain is incomplete (5513)' ;;
        5514) printf 'the private key does not match the certificate (5514)' ;;
        '')   printf '%s' "$1" ;;
        *)    printf 'DSM error %s' "${code}" ;;
    esac
}

# dsm_current_default — describe what DSM is serving now, for `status`.
dsm_current_default() {
    local id
    [ -r "${DSM_CERT_ARCHIVE}/DEFAULT" ] || return 1
    id="$(cat "${DSM_CERT_ARCHIVE}/DEFAULT")"
    printf '%s' "${id}"
}
