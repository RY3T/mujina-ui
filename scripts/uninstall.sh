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
# Remove sysvinit rc.d autostart symlinks (no-op under procd, which
# uses its own enable/disable).
for d in /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d; do
    rm -f "$d"/S92mujina-ui "$d"/K10mujina-ui \
          "$d"/disabled.S92mujina-ui "$d"/disabled.K10mujina-ui 2>/dev/null || true
done
# Migration: earlier versions added an /etc/rc.local entry; strip it
# too, in case the system was first installed before the rc.d switch.
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
