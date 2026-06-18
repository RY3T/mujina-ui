#!/usr/bin/env bash
# Remove mujina-ui from a miner.
#
# Usage:
#   scripts/uninstall.sh <ssh-target> [--purge]
#
# Without --purge, /etc/default/mujina-ui is preserved so a
# later re-install keeps your configuration. With --purge, every file
# the installer placed is removed.

set -euo pipefail

case "${1:-}" in
    -h|--help|"")
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

SSH_TARGET="$1"
PURGE="${2:-}"

ssh "$SSH_TARGET" "PURGE='$PURGE' sh -s" <<'REMOTE'
set -e
if [ -x /etc/init.d/mujina-ui ]; then
    /etc/init.d/mujina-ui stop  2>/dev/null || true
    /etc/init.d/mujina-ui disable 2>/dev/null || true
    rm -f /etc/init.d/mujina-ui
fi
# Remove the sysvinit-mode autostart hook from /etc/rc.local (no-op
# under procd, which uses its own enable/disable).
if [ -f /etc/rc.local ] && grep -q 'mujina-ui start' /etc/rc.local; then
    grep -v 'mujina-ui start' /etc/rc.local > /etc/rc.local.tmp
    mv /etc/rc.local.tmp /etc/rc.local
    chmod 0755 /etc/rc.local
fi
rm -f /usr/bin/mujina-ui /var/run/mujina-ui.pid
if [ "$PURGE" = "--purge" ]; then
    rm -f /etc/default/mujina-ui
    echo "purged"
else
    echo "uninstalled (kept /etc/default/mujina-ui; pass --purge to remove)"
fi
REMOTE
