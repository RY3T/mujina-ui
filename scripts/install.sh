#!/usr/bin/env bash
# Install mujina-ui onto a miner running LuxOS (or any
# OpenWrt-derived firmware with procd) that already has mujina-minerd
# running.
#
# Usage:
#   scripts/install.sh <ssh-target> [binary-path]
#
# Examples:
#   scripts/install.sh root@192.168.1.222
#   scripts/install.sh miner.lan ./target/aarch64-unknown-linux-musl/release/mujina-ui
#
# The script is idempotent -- safe to re-run for upgrades. It will
# stop the running service, replace the binary, and restart.
#
# What it installs:
#   /usr/bin/mujina-ui          -- the binary
#   /etc/default/mujina-ui      -- env-var configuration
#   /etc/init.d/mujina-ui       -- procd init script (autostart on boot)

set -euo pipefail

DEFAULT_BINARY="target/aarch64-unknown-linux-musl/release/mujina-ui"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    -h|--help|"") usage 0 ;;
esac

SSH_TARGET="$1"
BINARY="${2:-$DEFAULT_BINARY}"

[ -f "$BINARY" ] || die "binary not found: $BINARY
   Build first with:
     CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-unknown-linux-musl-gcc \\
     CC_aarch64_unknown_linux_musl=aarch64-unknown-linux-musl-gcc \\
     cargo build --release --target aarch64-unknown-linux-musl"

# Quick sanity check: confirm the binary is aarch64 ELF.
if command -v file >/dev/null 2>&1; then
    case "$(file -b "$BINARY")" in
        *aarch64*ELF*|*"ARM aarch64"*) : ;;
        *) warn "binary doesn't look like aarch64 ELF; install may fail on the miner" ;;
    esac
fi

log "checking SSH connection to $SSH_TARGET"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" 'true' \
    || die "cannot ssh to $SSH_TARGET (need passwordless / agent auth)"

log "probing miner"
PROBE=$(ssh "$SSH_TARGET" 'sh -s' <<'REMOTE'
set -e
echo "uname=$(uname -srm)"
# procd is the OpenWrt service supervisor LuxOS uses. Stock Antminer
# firmwares (PetaLinux / Yocto) use plain sysvinit instead. We support
# both: procd-style init script if procd is detected, otherwise a
# minimal sysvinit script driven by /etc/rc.local-equivalent autostart.
if [ -f /etc/rc.common ] && command -v procd >/dev/null 2>&1; then
    echo "init=procd"
elif [ -d /etc/init.d ]; then
    echo "init=sysvinit"
else
    echo "init=none"
fi
if curl -sS -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:7785/api/v0/health 2>/dev/null \
        | grep -q '^200$'; then
    echo "mujina=running"
else
    echo "mujina=down"
fi
REMOTE
)
echo "$PROBE" | sed 's/^/    /'

case "$PROBE" in
    *init=none*) die "remote has no init system we recognise (no procd, no /etc/init.d)." ;;
esac
case "$PROBE" in
    *mujina=running*) : ;;
    *) warn "mujina REST is not responding on :7785 -- the bridge will start anyway and retry, but you'll want to start mujina afterwards." ;;
esac

INIT_KIND=$(echo "$PROBE" | sed -n 's/^init=//p')
log "using $INIT_KIND init"

# scp uses the legacy SCP protocol because LuxOS / busybox dropbear has
# no sftp-server. -O forces SCP on modern OpenSSH clients.
log "uploading binary ($(du -h "$BINARY" | awk '{print $1}'))"
scp -q -O "$BINARY" "$SSH_TARGET:/tmp/mujina-ui.new"

log "installing service"
ssh "$SSH_TARGET" "INIT_KIND='$INIT_KIND' sh -s" <<'REMOTE'
set -e

# Stop the service if it exists and is running, before replacing the
# binary -- avoids "text file busy" and orphaned old processes.
if [ -x /etc/init.d/mujina-ui ]; then
    /etc/init.d/mujina-ui stop 2>/dev/null || true
    sleep 1
fi

# Move into place atomically and make executable.
mv /tmp/mujina-ui.new /usr/bin/mujina-ui
chmod 0755 /usr/bin/mujina-ui
rm -f /tmp/mujina-ui.new

# Defaults file. Created on first install only -- preserves operator
# overrides on upgrade.
if [ ! -f /etc/default/mujina-ui ]; then
    cat > /etc/default/mujina-ui <<'EOF'
# mujina-ui configuration. All variables optional.
# Restart the service after editing: /etc/init.d/mujina-ui restart

# Web UI HTTP bind address
# MUJINA_UI_LISTEN=0.0.0.0:7782

# Where mujina-minerd's REST API lives
# MUJINA_API_URL=http://127.0.0.1:7785

# Where mujina-minerd writes its log (the UI tails this file)
# MUJINA_UI_LOG_PATH=/var/log/mujina-minerd.log

# Log filter (info, debug, trace, etc.)
# RUST_LOG=info
EOF
fi

# Init script. Always overwritten so upgrades pick up changes.
case "$INIT_KIND" in
procd)
    cat > /etc/init.d/mujina-ui <<'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG=/usr/bin/mujina-ui
DEFAULTS=/etc/default/mujina-ui

start_service() {
    [ -f "$DEFAULTS" ] && . "$DEFAULTS"
    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param env \
        MUJINA_UI_LISTEN="${MUJINA_UI_LISTEN:-0.0.0.0:7782}" \
        MUJINA_API_URL="${MUJINA_API_URL:-http://127.0.0.1:7785}" \
        MUJINA_UI_LOG_PATH="${MUJINA_UI_LOG_PATH:-/var/log/mujina-minerd.log}" \
        RUST_LOG="${RUST_LOG:-info}"
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    ;;
sysvinit)
    cat > /etc/init.d/mujina-ui <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          mujina-ui
# Required-Start:    networking
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: mujina-ui (web dashboard for mujina-miner)
### END INIT INFO

# Non-login ssh sessions and rc.d don't include /sbin in PATH.
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin

PROG=/usr/bin/mujina-ui
PIDFILE=/var/run/mujina-ui.pid
LOGFILE=/var/log/mujina-ui.log
DEFAULTS=/etc/default/mujina-ui

# shellcheck disable=SC1090
[ -f "$DEFAULTS" ] && . "$DEFAULTS"
export MUJINA_UI_LISTEN MUJINA_API_URL MUJINA_UI_LOG_PATH RUST_LOG

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

start() {
    if is_running; then
        echo "already running (pid $(cat "$PIDFILE"))"
        return 0
    fi
    nohup "$PROG" >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    echo "started pid $(cat "$PIDFILE")"
}

stop() {
    if is_running; then
        kill "$(cat "$PIDFILE")"
        rm -f "$PIDFILE"
        echo "stopped"
    fi
}

status() {
    if is_running; then
        echo "running (pid $(cat "$PIDFILE"))"
    else
        echo "stopped"
        return 1
    fi
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    enable|disable) : ;;  # autostart wiring is handled by install.sh
    *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
EOF
    # Autostart on boot. Place rc.d symlinks at S92 (after mujina-init
    # at S90 and mujina-ry3t-mqtt-init at S91, when those exist) and
    # K10 for clean shutdown. This is what stock LuxOS / PetaLinux
    # actually executes; /etc/rc.local is not in their boot path on
    # this rootfs.
    for d in /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d; do
        [ -d "$d" ] || continue
        rm -f "$d/S92mujina-ui" "$d/disabled.S92mujina-ui"
        ln -sf ../init.d/mujina-ui "$d/S92mujina-ui"
    done
    for d in /etc/rc0.d /etc/rc1.d /etc/rc6.d; do
        [ -d "$d" ] || continue
        rm -f "$d/K10mujina-ui" "$d/disabled.K10mujina-ui"
        ln -sf ../init.d/mujina-ui "$d/K10mujina-ui"
    done
    # Migration: earlier versions of this installer added an
    # /etc/rc.local entry; remove it now that the rc.d symlinks are in
    # place. Leaving it would just run start a second time at boot
    # (harmless) but it's cleaner to take it out.
    if [ -f /etc/rc.local ] && grep -q 'mujina-ui start' /etc/rc.local; then
        grep -v 'mujina-ui start' /etc/rc.local > /etc/rc.local.tmp
        mv /etc/rc.local.tmp /etc/rc.local
        chmod 0755 /etc/rc.local
    fi
    ;;
esac
chmod 0755 /etc/init.d/mujina-ui

# Enable autostart (no-op on sysvinit handled above) and start now.
/etc/init.d/mujina-ui enable 2>/dev/null || true
/etc/init.d/mujina-ui start
REMOTE

log "verifying service started"
sleep 2
PORTS=$(ssh "$SSH_TARGET" 'netstat -ltn 2>/dev/null | awk "{print \$4}" | grep -E ":7782$" | sort -u' || true)
[ -n "$PORTS" ] || die "service started but :7782 is not listening; check 'logread' on the miner"

log "installed. listening on:"
echo "$PORTS" | sed 's/^/    /'

HOST_ONLY="${SSH_TARGET#*@}"
log "web UI: http://$HOST_ONLY:7782"
log "logs:    ssh $SSH_TARGET 'logread -f | grep mujina-ui'"
log "config:  ssh $SSH_TARGET 'vi /etc/default/mujina-ui' && /etc/init.d/mujina-ui restart"
