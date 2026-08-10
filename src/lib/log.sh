#!/usr/bin/env bash
# log.sh — logging primitives shared by the CLI and the SPK control scripts.
#
# Everything goes to stderr so that stdout stays clean for values that callers
# capture with $(...). During package install DSM tees control-script output to
# /var/log/packages/<pkg>.log, so this is also the package's install log.

SYNOLE_LOG_LEVEL="${SYNOLE_LOG_LEVEL:-info}"

_log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${level}" "$*" >&2
}

log_debug() {
    [ "${SYNOLE_LOG_LEVEL}" = "debug" ] || return 0
    _log DEBUG "$@"
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

# die <message...> — log and exit non-zero.
die() {
    log_error "$@"
    exit 1
}

# redact <string> — render a secret safe to log. Shows only the last 4 chars so
# a user can confirm which credential is in play without leaking it.
redact() {
    local s="$1"
    if [ "${#s}" -le 8 ]; then
        printf '****'
    else
        printf '****%s' "${s: -4}"
    fi
}
