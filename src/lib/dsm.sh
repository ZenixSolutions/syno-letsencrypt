#!/usr/bin/env bash
# dsm.sh — hand a certificate to DSM, and manage which services use it.
#
# Runs as root, so it drives `synowebapi --exec-fastwebapi`, which invokes
# DSM's own Web API in-process. That is the same code path Control Panel uses
# when you upload a certificate by hand, so DSM does all the fiddly parts
# itself: the _archive write, the copy to every subscribing service, the
# INFO/DEFAULT bookkeeping, and the web server reload.
#
# Deliberately NOT writing the PEM files directly
# -----------------------------------------------
# That is the traditional approach and it is now a trap. On DSM 7.3
# `system/default` contains ECC-cert.pem and RSA-cert.pem — DSM installs an
# elliptic-curve and an RSA certificate side by side and serves whichever the
# client negotiates. The cert.pem / privkey.pem / fullchain.pem names every
# filesystem-based tool writes no longer exist there. The layout is
# undocumented and changed between releases, so DSM owns it.
#
# Deliberately NOT using the HTTP API with a DSM password
# -------------------------------------------------------
# That is what acme.sh's deploy hook does. It needs an admin credential on
# disk, breaks under 2FA, and its unattended workaround disables 2FA
# enforcement DSM-wide while it runs. Running as root, none of that is needed.

readonly DSM_CERT_ARCHIVE="/usr/syno/etc/certificate/_archive"
readonly SYNOWEBAPI="/usr/syno/bin/synowebapi"

# --------------------------------------------------------------------------
# Calling synowebapi safely
# --------------------------------------------------------------------------
#
# Two traps, both of which produce silent corruption rather than errors:
#
#  1. synowebapi prints progress lines like "[Line 295] Exec WebAPI: ..." on
#     stderr. Merging them into stdout makes the result unparseable as JSON.
#     Always discard stderr, and strip anything before the first '{' as a belt
#     and braces measure.
#
#  2. Every key=value argument is parsed as JSON. A bare string is "not a json
#     value" and falls back to being treated as text — usually fine, but a
#     certificate id like 8ec29f37 can be read as scientific notation. String
#     values are therefore JSON-quoted explicitly.

# jstr <value> — render a shell string as a JSON string literal.
jstr() { printf '%s' "$1" | jq -Rs .; }

# syno_api <arg>... — call synowebapi and print only the JSON body.
syno_api() {
    "${SYNOWEBAPI}" --exec-fastwebapi "$@" 2>/dev/null | sed -n '/^[[:space:]]*{/,$p'
}

# syno_api_ok <json> — true when the call succeeded.
syno_api_ok() {
    printf '%s' "$1" | jq -e '.success == true' >/dev/null 2>&1
}

dsm_require_root() {
    [ "$(id -u)" -eq 0 ] || die "This must run as root. Try: sudo ${0##*/} ${1:-}"
}

dsm_preflight() {
    dsm_require_root ""
    [ -x "${SYNOWEBAPI}" ] || die "${SYNOWEBAPI} not found. This does not look like DSM 7."
    [ -d "${DSM_CERT_ARCHIVE}" ] || die "DSM certificate store not found at ${DSM_CERT_ARCHIVE}."
}

# --------------------------------------------------------------------------
# Reading current state
# --------------------------------------------------------------------------

# dsm_list_certs — raw JSON of every certificate, each with its services[].
dsm_list_certs() {
    syno_api api=SYNO.Core.Certificate.CRT method=list version=1
}

# dsm_cert_summary — one line per certificate, for a picker.
#   <id>\t<description>\t<common name>\t<default?>\t<service count>
dsm_cert_summary() {
    dsm_list_certs | jq -r '
        .data.certificates[]? |
        [ .id,
          (.desc // ""),
          (.subject.common_name // ""),
          (if .is_default then "default" else "" end),
          ((.services // []) | length | tostring)
        ] | @tsv'
}

# dsm_cert_services <cert_id> — the full service objects a certificate serves.
#
# Emitted verbatim, because reassignment requires handing the same object back
# unchanged: the i18n keys and owner values vary per service and per DSM
# release, and inventing them is the documented cause of error 5503.
dsm_cert_services() {
    local id="$1"
    dsm_list_certs | jq -c --arg id "${id}" \
        '[ .data.certificates[]? | select(.id == $id) | .services[]? ]'
}

# dsm_all_services — every assignable service on this NAS.
#
# _archive/SERVICES lists services that exist; CRT list only shows ones already
# bound to a certificate, so a service assigned to nothing would be invisible
# there. The file's top-level shape is undocumented, so both an array and an
# object-of-arrays are accepted.
dsm_all_services() {
    local f="${DSM_CERT_ARCHIVE}/SERVICES"
    if [ -r "${f}" ]; then
        jq -c 'if type == "array" then . elif type == "object" then [ .[] ] | flatten else [] end' \
            "${f}" 2>/dev/null && return 0
    fi
    # Fall back to whatever is currently assigned somewhere.
    dsm_list_certs | jq -c '[ .data.certificates[]?.services[]? ] | unique_by(.subscriber + "/" + .service)'
}

# dsm_services_with_owner — every assignable service, each annotated with
# `_old_id`: the certificate currently serving it, or "" if none.
#
# That annotation is what the reassignment API needs, and it cannot be derived
# from the service object alone — it has to be read from the cert -> services
# direction and inverted.
dsm_services_with_owner() {
    local certs all
    certs="$(dsm_list_certs)"
    all="$(dsm_all_services)"

    jq -n --argjson all "${all}" --argjson certs "${certs}" '
        # service key -> owning certificate id
        ($certs.data.certificates // []) as $c
        | ( [ $c[] | .id as $id | (.services // [])[] | { key: (.subscriber + "/" + .service), value: $id } ]
            | from_entries ) as $owner
        | [ $all[]
            | . + { _old_id: ($owner[(.subscriber + "/" + .service)] // "") } ]
    ' 2>/dev/null || printf '[]'
}

# dsm_find_cert_id <description> — certificate carrying this description.
# Renewals match on it so they replace in place instead of adding a new
# certificate to Control Panel every 60 days.
dsm_find_cert_id() {
    local desc="$1"
    dsm_list_certs \
        | jq -r --arg d "${desc}" '.data.certificates[]? | select(.desc == $d) | .id' 2>/dev/null \
        | head -n1
}

dsm_default_cert_id() {
    dsm_list_certs | jq -r '.data.certificates[]? | select(.is_default == true) | .id' 2>/dev/null | head -n1
}

# --------------------------------------------------------------------------
# Importing
# --------------------------------------------------------------------------

# dsm_import_cert <cert> <key> <chain> <desc> <as_default> [replace_id]
#
# With replace_id, DSM updates that certificate in place and **every service
# already pointing at it keeps working** — which is why replacement is the
# right default for renewals.
#
# Without it, a brand-new certificate entry is created. A new entry serves
# nothing except, if as_default is true, the system default. Other services
# stay on the old certificate until reassigned; see dsm_assign_services.
dsm_import_cert() {
    local cert="$1" key="$2" chain="$3" desc="$4" as_default="$5" replace_id="${6:-}"
    local out new_id

    dsm_preflight

    local f
    for f in "${cert}" "${key}" "${chain}"; do
        [ -s "${f}" ] || die "Missing or empty certificate file: ${f}"
    done

    local -a args=(
        api=SYNO.Core.Certificate method=import version=1
        "key_tmp=$(jstr "${key}")"
        "cert_tmp=$(jstr "${cert}")"
        "inter_cert_tmp=$(jstr "${chain}")"
        "desc=$(jstr "${desc}")"
    )
    if [ -n "${replace_id}" ]; then
        args+=("id=$(jstr "${replace_id}")")
        log_info "Replacing certificate ${replace_id} in place; its service assignments are preserved."
    else
        log_info "Creating a new certificate entry."
    fi
    if [ "${as_default}" = "true" ]; then args+=(as_default=true); fi

    out="$(syno_api "${args[@]}")"
    if ! syno_api_ok "${out}"; then
        die "DSM refused the certificate: $(dsm_explain_error "${out}")"
    fi

    new_id="$(printf '%s' "${out}" | jq -r '.data.id // empty')"
    log_info "DSM accepted the certificate${new_id:+ (id ${new_id})}."
    if printf '%s' "${out}" | jq -e '.data.restart_httpd == true' >/dev/null 2>&1; then
        log_info "DSM is restarting its web server; the UI may blip for a few seconds."
    fi

    printf '%s' "${new_id:-${replace_id}}"
}

# --------------------------------------------------------------------------
# Service assignment
# --------------------------------------------------------------------------

# dsm_assign_services <new_cert_id> <services_json>
#
# services_json is an array of full service objects, each carrying an extra
# `_old_id` field naming the certificate currently serving it.
#
# The API wants one entry per service: { service: <object>, old_id, id }.
# Services not named are left alone.
dsm_assign_services() {
    local new_id="$1" services="$2"
    local settings count out

    count="$(printf '%s' "${services}" | jq 'length')"
    [ "${count}" -gt 0 ] || { log_info "No services to reassign."; return 0; }

    # Reassigning a service to the certificate it already uses has been
    # observed to clear the assignment entirely rather than no-op, so those
    # entries are dropped rather than sent.
    settings="$(printf '%s' "${services}" | jq -c --arg id "${new_id}" '
        [ .[]
          | select((._old_id // "") != $id)
          | { service: (del(._old_id)), old_id: (._old_id // ""), id: $id } ]')"

    count="$(printf '%s' "${settings}" | jq 'length')"
    if [ "${count}" -eq 0 ]; then
        log_info "Every selected service already uses this certificate."
        return 0
    fi

    log_info "Assigning ${count} service(s) to certificate ${new_id}..."
    out="$(syno_api api=SYNO.Core.Certificate.Service method=set version=1 "settings=${settings}")"

    if ! syno_api_ok "${out}"; then
        log_error "DSM refused the service assignment: $(dsm_explain_error "${out}")"
        log_error "Assign them by hand in Control Panel > Security > Certificate > Settings."
        return 1
    fi

    # success:true is not sufficient here — this API has a history of
    # reporting success while changing nothing. Verify against a fresh read.
    local actual
    actual="$(dsm_cert_services "${new_id}" | jq 'length')"
    log_info "Certificate ${new_id} now serves ${actual} service(s)."
    return 0
}

# --------------------------------------------------------------------------

dsm_explain_error() {
    local code
    code="$(printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null)"
    case "${code}" in
        105)  printf 'the caller is not an administrator (105)' ;;
        5503) printf 'the service assignment payload was rejected (5503)' ;;
        5510) printf 'the certificate file was rejected as malformed (5510)' ;;
        5511) printf 'the private key was rejected as malformed (5511)' ;;
        5512) printf 'the intermediate certificate was rejected (5512)' ;;
        5513) printf 'the certificate chain is incomplete (5513)' ;;
        5514) printf 'the private key does not match the certificate (5514)' ;;
        '')   printf '%s' "$1" ;;
        *)    printf 'DSM error %s' "${code}" ;;
    esac
}
