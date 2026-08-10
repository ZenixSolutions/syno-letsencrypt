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
[ "${1:-}" = "--purge" ] && PURGE=true

echo "Stopping the renewal timer..."
systemctl disable --now syno-letsencrypt.timer 2>/dev/null || true
rm -f /etc/systemd/system/syno-letsencrypt.timer \
      /etc/systemd/system/syno-letsencrypt.service
systemctl daemon-reload 2>/dev/null || true

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
