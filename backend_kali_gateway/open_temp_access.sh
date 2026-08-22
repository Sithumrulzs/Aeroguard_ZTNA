#!/bin/bash
# =============================================================================
#  AeroGuard ZTNA — Temporarily Open the Dark-Mode Firewall (testing only)
#
#  Suspends the INPUT drop-all for a bounded window, then automatically
#  re-locks back into dark mode by re-running setup_darkmode.sh — the
#  window is enforced by a detached watcher, so closing this terminal (or
#  simply forgetting about it) can never leave the gateway open
#  indefinitely. FORWARD/NAT rules (vendor/laptop routing) are untouched;
#  this only affects direct inbound reachability to the gateway itself.
#
#      sudo bash open_temp_access.sh [minutes]      # default 5
#      sudo bash open_temp_access.sh --relock-now    # re-lock immediately
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_PID_FILE="/tmp/aeroguard_temp_open.pid"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Run as root: sudo bash open_temp_access.sh"
    exit 1
fi

# Cancel any watcher from a previous invocation — re-running this script
# (with or without --relock-now) always means "reset to this new state",
# not "stack another pending re-lock on top of the old one".
if [ -f "$WATCHER_PID_FILE" ]; then
    OLD_WATCHER=$(cat "$WATCHER_PID_FILE" 2>/dev/null)
    [ -n "$OLD_WATCHER" ] && kill "$OLD_WATCHER" 2>/dev/null
    rm -f "$WATCHER_PID_FILE"
fi

if [ "$1" = "--relock-now" ]; then
    echo "[*] Re-locking firewall now..."
    bash "$SCRIPT_DIR/setup_darkmode.sh"
    exit 0
fi

MINUTES="${1:-5}"

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   WARNING — FIREWALL TEMPORARILY OPEN             ║"
echo "  ╠══════════════════════════════════════════════════╣"
printf "  ║   All inbound traffic ACCEPTED for %-3s minute(s)   ║\n" "$MINUTES"
echo "  ║   Dark mode / SPA drop-all is SUSPENDED           ║"
echo "  ║   Auto re-lock is scheduled — no action needed    ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""

# Open — clears INPUT entirely and accepts everything. FORWARD/NAT (vendor
# and laptop routing) are left exactly as they were.
iptables -F INPUT
iptables -P INPUT ACCEPT

echo "[*] Firewall open. Re-lock early any time with:"
echo "      sudo bash open_temp_access.sh --relock-now"
echo ""

# Detached watcher (setsid, not just nohup) — survives this terminal
# closing, since the entire point is this can never be silently forgotten
# and left open past its window.
setsid nohup bash -c "
    sleep $((MINUTES * 60))
    echo \"[*] Testing window elapsed — re-locking dark mode...\"
    bash '$SCRIPT_DIR/setup_darkmode.sh'
    rm -f '$WATCHER_PID_FILE'
" >/tmp/aeroguard_temp_open.log 2>&1 &

echo $! > "$WATCHER_PID_FILE"
echo "[*] Auto re-lock scheduled in ${MINUTES}m (watcher PID $!)."
