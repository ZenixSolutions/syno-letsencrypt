#!/usr/bin/env bash
#
# uninstall.sh — remove syno-letsencrypt.
#
#   sudo ./uninstall.sh            keep the certificate and configuration
#   sudo ./uninstall.sh --purge    also delete them
#
# The certificate already installed in DSM is always left alone. Removing this
# tool should never drop your NAS back to a self-signed certificate.
#
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

PURGE=false
if [ "${1:-}" = "--purge" ]; then PURGE=true; fi

LIB_DIR="/usr/local/share/syno-letsencrypt/lib"
if [ -r "${LIB_DIR}/log.sh" ]; then
    # shellcheck source=src/lib/log.sh
    . "${LIB_DIR}/log.sh"
    # shellcheck source=src/lib/dsm.sh
    . "${LIB_DIR}/dsm.sh"
    # shellcheck source=src/lib/schedule.sh
    . "${LIB_DIR}/schedule.sh"
    echo "Removing the scheduled task..."
    sched_remove || true
else
    echo "Program files already gone; remove the task in Control Panel > Task Scheduler."
fi

# Clean up the systemd units earlier versions installed, so upgrading from one
# of those does not leave a second renewal running alongside the DSM task.
if [ -f /etc/systemd/system/syno-letsencrypt.timer ]; then
    echo "Removing the systemd timer left by an earlier version..."
    systemctl disable --now syno-letsencrypt.timer 2>/dev/null || true
    rm -f /etc/systemd/system/syno-letsencrypt.timer \
          /etc/systemd/system/syno-letsencrypt.service
    systemctl daemon-reload 2>/dev/null || true
fi

echo "Removing program files..."
rm -f  /usr/local/bin/syno-letsencrypt
rm -rf /usr/local/share/syno-letsencrypt

if [ "${PURGE}" = true ]; then
    echo "Removing configuration, ACME account and certificates..."
    rm -rf /usr/local/etc/syno-letsencrypt
    echo ""
    echo "Note: lego was left at /usr/local/bin/lego in case something else uses it."
    echo "Delete your Cloudflare API token at https://dash.cloudflare.com/profile/api-tokens"
else
    echo ""
    echo "Kept /usr/local/etc/syno-letsencrypt (config, ACME account, certificates)."
    echo "Reinstalling will pick up where this left off. Use --purge to remove it."
fi

echo ""
echo "The certificate currently installed in DSM has not been touched."
