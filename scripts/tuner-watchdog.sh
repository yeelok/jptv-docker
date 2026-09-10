#!/bin/bash
# Tuner watchdog — recovers the stack when tuner device nodes are late or missing.
#
# Why this exists: mirakc's compose entry lists all eight tuner device nodes, and
# Docker fails at *container creation* when one is absent:
#
#   Error response from daemon: error gathering device information while adding
#   custom device "/dev/pxmlt8video5": no such file or directory
#
# A creation failure never reaches the restart policy, so mirakc stays
# Exited(255) forever and KonomiTV crash-loops behind it (it validates
# mirakurun_url at startup). The whole stack is then silently down until a human
# notices — which is exactly how a three-day outage happened when the hypervisor
# failed to present one of the card's two USB devices at VM boot.
#
# The real fix is host-side (VFIO passthrough of the card rather than forwarding
# its two USB devices). This watchdog is the guest-side safety net: it brings the
# stack up by itself the moment the devices are all present.
set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-/home/ubuntu/tv}"
DEVICES=(/dev/pxmlt8card0 /dev/pxmlt8video{0..7})
SERVICES=(mirakc b25 bcas edcb postrec konomitv)

log() { echo "tuner-watchdog: $*"; }

# Maintenance switch, so a deliberate `docker stop` during debugging isn't undone.
if [ -e "$PROJECT_DIR/.watchdog-disabled" ]; then
    log "disabled (.watchdog-disabled present); doing nothing"
    exit 0
fi

check_missing() {
    missing=()
    for d in "${DEVICES[@]}"; do [ -e "$d" ] || missing+=("$d"); done
}

check_missing
if [ ${#missing[@]} -gt 0 ]; then
    log "WARNING: ${#missing[@]} device(s) missing: ${missing[*]}"
    # Re-enumerate the card's USB devices. Harmless when they are healthy, and it
    # recovers a device the kernel bound but left in a no-data state. It cannot
    # conjure a device the hypervisor never presented.
    for dev in /sys/bus/usb/devices/*; do
        [ -r "$dev/idVendor" ] || continue
        [ "$(cat "$dev/idVendor" 2>/dev/null)" = "0511" ] || continue
        log "re-enumerating $(basename "$dev")"
        echo 0 > "$dev/authorized" 2>/dev/null
        sleep 2
        echo 1 > "$dev/authorized" 2>/dev/null
    done
    sleep 8
    check_missing
    if [ ${#missing[@]} -gt 0 ]; then
        log "ERROR: still missing after re-enumeration: ${missing[*]}"
        log "ERROR: the hypervisor is not presenting the card's USB device(s) — fix on the host"
        exit 1
    fi
    log "all devices present after re-enumeration"
fi

cd "$PROJECT_DIR" || { log "ERROR: cannot cd to $PROJECT_DIR"; exit 1; }

# Start anything that is not running. `up -d` is idempotent, so this is a no-op
# on a healthy system; we check first only to keep the logs quiet.
running=$(docker compose ps --services --filter status=running 2>/dev/null)
down=()
for s in "${SERVICES[@]}"; do
    grep -qx "$s" <<<"$running" || down+=("$s")
done

if [ ${#down[@]} -eq 0 ]; then
    exit 0
fi

log "services down: ${down[*]} — bringing the stack up"
if docker compose up -d 2>&1 | sed 's/^/tuner-watchdog:   /'; then
    log "docker compose up -d completed"
else
    log "ERROR: docker compose up -d failed"
    exit 1
fi
