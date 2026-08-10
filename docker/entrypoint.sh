#!/usr/bin/env bash
# Container entrypoint. Validates configuration once, loudly, at startup —
# a certificate tool that only reveals its misconfiguration 60 days later,
# when the old certificate expires, is worse than useless.
set -euo pipefail

# shellcheck source=src/lib/log.sh
. /app/lib/log.sh

log_info "syno-letsencrypt starting"

missing=()
for v in CLOUDFLARE_DNS_API_TOKEN DOMAINS ACME_EMAIL DSM_URL DSM_USERNAME DSM_PASSWORD; do
    [ -n "${!v:-}" ] || missing+=("${v}")
done
if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing required settings: ${missing[*]}"
    log_error "See https://github.com/ZenixSolutions/syno-letsencrypt#configuration"
    exit 1
fi

# Prove everything works before entering the renewal loop, so a bad token or a
# non-admin DSM account surfaces now rather than at the first renewal.
if ! /app/bin/syno-letsencrypt check; then
    log_error "Startup checks failed. Fix the above and restart the container."
    exit 1
fi

/app/bin/syno-letsencrypt renew || log_error "Initial renewal failed; will retry."

INTERVAL="${CHECK_INTERVAL:-43200}"   # 12h
log_info "Entering renewal loop; checking every ${INTERVAL}s"

# Trap so `docker stop` exits promptly instead of waiting out the sleep.
trap 'log_info "Shutting down."; exit 0' TERM INT

while true; do
    sleep "${INTERVAL}" &
    wait $!
    /app/bin/syno-letsencrypt renew || log_error "Renewal attempt failed; will retry in ${INTERVAL}s."
done
