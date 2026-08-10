#!/usr/bin/env bash
# dsm.sh — installing a certificate into DSM's own certificate store.
#
# Two strategies, in order of preference:
#
#   1. synowebapi --exec-fastwebapi
#      Runs DSM's Web API in-process as root. Same code path the DSM UI uses,
#      so DSM itself updates _archive/INFO, DEFAULT, every subscriber service
#      directory, and restarts httpd. No credentials, no HTTP, no port
#      guessing, no 2FA. Undocumented, so it is wrapped in error handling.
#
#   2. Direct _archive write + synow3tool --gen-all
#      Fallback for DSM builds where the synowebapi invocation differs. Writes
#      the PEMs, copies them to each subscribing service, regenerates the nginx
#      config and restarts it.
#
# Explicitly NOT implemented: acme.sh's HTTP deploy path. It needs a DSM admin
# username and password, breaks on 2FA, and its SYNO_USE_TEMP_ADMIN workaround
# disables 2FA enforcement DSM-wide for the duration of the call — if the
# script dies in between, 2FA stays off. A package already runs as root; there
# is no reason to accept that risk.

readonly DSM_CERT_ARCHIVE="/usr/syno/etc/certificate/_archive"
readonly SYNOWEBAPI="/usr/syno/bin/synowebapi"
readonly SYNOW3TOOL="/usr/syno/bin/synow3tool"

dsm_require_root() {
    [ "$(id -u)" -eq 0 ] || die "This operation must run as root."
}

# dsm_find_cert_id_by_desc <description>
# Prints the existing certificate id whose description matches, or nothing.
dsm_find_cert_id_by_desc() {
    local desc="$1" out

    out="$("${SYNOWEBAPI}" --exec-fastwebapi \
        api=SYNO.Core.Certificate.CRT method=list version=1 2>/dev/null)" || return 0

    printf '%s' "${out}" \
        | jq -r --arg d "${desc}" \
            '.data.certificates[]? | select(.desc == $d) | .id' 2>/dev/null \
        | head -n1
}

# dsm_import_cert <cert.pem> <privkey.pem> <chain.pem> <description> <as_default>
#
# Replaces the existing certificate with the same description if one exists, so
# renewals update in place rather than accumulating new entries every 60 days.
dsm_import_cert() {
    local cert="$1" key="$2" chain="$3" desc="$4" as_default="$5"
    local existing_id out

    dsm_require_root

    [ -s "${cert}" ]  || die "Certificate file is missing or empty: ${cert}"
    [ -s "${key}" ]   || die "Private key file is missing or empty: ${key}"
    [ -s "${chain}" ] || die "Chain file is missing or empty: ${chain}"

    existing_id="$(dsm_find_cert_id_by_desc "${desc}")"
    if [ -n "${existing_id}" ]; then
        log_info "Replacing existing DSM certificate '${desc}' (id=${existing_id})"
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
        "as_default=${as_default}"
    )
    [ -n "${existing_id}" ] && args+=("id=${existing_id}")

    if ! out="$("${SYNOWEBAPI}" "${args[@]}" 2>&1)"; then
        log_warn "synowebapi import failed, falling back to direct archive write."
        log_debug "synowebapi output: ${out}"
        dsm_import_cert_fallback "${cert}" "${key}" "${chain}"
        return $?
    fi

    if ! printf '%s' "${out}" | jq -e '.success == true' >/dev/null 2>&1; then
        log_warn "synowebapi reported failure: $(dsm_explain_error "${out}")"
        dsm_import_cert_fallback "${cert}" "${key}" "${chain}"
        return $?
    fi

    log_info "Certificate installed into DSM."
    if printf '%s' "${out}" | jq -e '.data.restart_httpd == true' >/dev/null 2>&1; then
        log_info "DSM is restarting its web server; the UI may blip for a few seconds."
    fi
    return 0
}

# dsm_explain_error <synowebapi_json> — turn a DSM error code into English.
dsm_explain_error() {
    local code
    code="$(printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null)"
    case "${code}" in
        5510) printf 'illegal certificate file (code 5510)' ;;
        5511) printf 'illegal private key file (code 5511)' ;;
        5512) printf 'illegal intermediate certificate (code 5512)' ;;
        5514) printf 'private key does not match the certificate (code 5514)' ;;
        '')   printf '%s' "$1" ;;
        *)    printf 'DSM error code %s' "${code}" ;;
    esac
}

# dsm_import_cert_fallback <cert.pem> <privkey.pem> <chain.pem>
#
# Writes into the archive entry pointed at by DEFAULT, propagates to every
# subscribing service directory, then regenerates and restarts nginx.
dsm_import_cert_fallback() {
    local cert="$1" key="$2" chain="$3"
    local default_id dest

    dsm_require_root

    [ -r "${DSM_CERT_ARCHIVE}/DEFAULT" ] \
        || die "Cannot read ${DSM_CERT_ARCHIVE}/DEFAULT — is this DSM 7?"

    default_id="$(cat "${DSM_CERT_ARCHIVE}/DEFAULT")"
    dest="${DSM_CERT_ARCHIVE}/${default_id}"
    [ -d "${dest}" ] || die "Default certificate directory not found: ${dest}"

    log_info "Writing certificate into ${dest}"
    install -m 400 -o root -g root "${cert}" "${dest}/cert.pem"
    install -m 400 -o root -g root "${key}"  "${dest}/privkey.pem"
    install -m 400 -o root -g root "${chain}" "${dest}/chain.pem"
    cat "${cert}" "${chain}" > "${dest}/fullchain.pem"
    chmod 400 "${dest}/fullchain.pem"

    dsm_propagate_to_services "${default_id}"

    log_info "Regenerating web server configuration"
    "${SYNOW3TOOL}" --gen-all \
        || log_warn "synow3tool --gen-all failed; nginx may still serve the old certificate."
    /usr/syno/bin/synosystemctl restart nginx \
        || log_warn "nginx restart failed."
}

# dsm_propagate_to_services <cert_id>
#
# DSM gives each subscribing service a COPY of the certificate, not a symlink,
# so every subscriber listed in _archive/INFO must be updated and reloaded.
dsm_propagate_to_services() {
    local cert_id="$1"
    local info="${DSM_CERT_ARCHIVE}/INFO"
    local subscriber service cert_path reload

    [ -s "${info}" ] || { log_warn "No ${info}; skipping service propagation."; return 0; }

    while IFS=$'\t' read -r subscriber service; do
        [ -n "${subscriber}" ] || continue

        cert_path=""
        for base in /usr/local/etc/certificate /usr/syno/etc/certificate; do
            if [ -d "${base}/${subscriber}/${service}" ]; then
                cert_path="${base}/${subscriber}/${service}"
                break
            fi
        done

        if [ -z "${cert_path}" ]; then
            log_debug "No certificate directory for ${subscriber}/${service}; skipping."
            continue
        fi

        if cmp -s "${DSM_CERT_ARCHIVE}/${cert_id}/cert.pem" "${cert_path}/cert.pem"; then
            continue    # already current
        fi

        log_info "Updating certificate for ${subscriber}/${service}"
        cp "${DSM_CERT_ARCHIVE}/${cert_id}"/{cert,chain,fullchain,privkey}.pem "${cert_path}/"

        for base in /usr/libexec/certificate.d /usr/local/libexec/certificate.d \
                    /usr/syno/share/certificate.d /usr/local/share/certificate.d; do
            reload="${base}/${subscriber}"
            [ -x "${reload}" ] && { "${reload}" "${service}"; break; }
        done
    done < <(jq -r --arg id "${cert_id}" \
        '.[$id].services[]? | "\(.subscriber)\t\(.service)"' "${info}")
}
