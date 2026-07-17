#!/bin/bash
# =============================================================================
#  AeroGuard ZTNA — Gateway Launcher
#  Starts firewall, SPA sniffer, then FastAPI in one command.
#
#      sudo bash start_gateway.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Run as root: sudo bash start_gateway.sh"
    exit 1
fi

# Step 0: Force-sync the system clock. A VM left suspended (rather than
# rebooted) can drift several minutes — spa_sniffer.py rejects any knock
# whose embedded timestamp is more than 60s away from this machine's clock,
# so a stale clock here silently turns every real knock into a false
# "REPLAY". Tries whichever sync tool is actually installed; a one-shot
# step, not just re-enabling background sync, so the correction is
# immediate rather than eventual. Never blocks startup — if there's no
# network reachable right now, it just moves on.
echo "[*] Step 0 — Syncing system clock..."
timedatectl set-ntp true 2>/dev/null
if command -v chronyd &>/dev/null; then
    chronyd -q 'pool pool.ntp.org iburst' 2>/dev/null
elif command -v ntpdate &>/dev/null; then
    ntpdate -u pool.ntp.org 2>/dev/null
else
    systemctl restart systemd-timesyncd 2>/dev/null
    sleep 2
fi
echo "    System time: $(date)"

# Ensure conntrack CLI is available (needed to flush connection tracking on shutdown)
if ! command -v conntrack &>/dev/null; then
    echo "[*] Installing conntrack..."
    apt-get install -y -q conntrack 2>/dev/null
fi

# Step 1: Apply SPA firewall — flush all rules and enter dark mode
echo "[*] Step 1 — Applying SPA firewall (dark mode)..."
bash "$SCRIPT_DIR/setup_darkmode.sh"

# Step 2: Kill ALL leftover processes from any previous run, then start fresh.
# Name-pattern kills first (fast path for the common case), then a direct,
# name-agnostic kill of whatever actually holds port 8000 — covers stale
# processes from a VM suspend/resume or anything the patterns above miss,
# without depending on the `fuser`/psmisc binary being installed. Finally,
# poll until the port is *confirmed* free instead of guessing with a fixed
# sleep.
echo ""
echo "[*] Step 2 — Cleaning up previous run..."
pkill -9 -f "spa_sniffer.py"        2>/dev/null
pkill -9 -f "python3.*main\.py"     2>/dev/null
pkill -9 -f "uvicorn"               2>/dev/null

PORT_PIDS=$(ss -tlnp "sport = :8000" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u)
if [ -n "$PORT_PIDS" ]; then
    echo "    Killing stale process(es) on port 8000: $PORT_PIDS"
    kill -9 $PORT_PIDS 2>/dev/null
fi

for i in $(seq 1 10); do
    ss -tln 2>/dev/null | grep -q ':8000 ' || break
    sleep 0.5
done

if ss -tln 2>/dev/null | grep -q ':8000 '; then
    echo "    [!] Port 8000 still in use after cleanup — aborting."
    ss -tlnp 2>/dev/null | grep ':8000 '
    exit 1
fi
echo "    Port 8000 status: FREE"

echo "[*] Starting SPA knock sniffer (UDP 7777)..."
"$SCRIPT_DIR/venv/bin/python3" -u "$SCRIPT_DIR/spa_sniffer.py" &
SNIFFER_PID=$!
echo "    sniffer PID: $SNIFFER_PID"

# On exit: kill sniffer (triggers atexit → firewall cleanup) AND any gateway
trap 'echo "[*] Stopping sniffer and restoring dark mode..."; kill "$SNIFFER_PID" 2>/dev/null; wait "$SNIFFER_PID" 2>/dev/null; pkill -9 -f "python3.*main\.py" 2>/dev/null; fuser -k 8000/tcp 2>/dev/null' EXIT

# Brief pause to let the sniffer bind before the gateway starts
sleep 1

# Step 3: Start FastAPI gateway on loopback (reachable only after a verified knock)
echo ""
echo "[*] Step 3 — Starting AeroGuard Gateway (127.0.0.1:8000)..."
echo ""
cd "$SCRIPT_DIR"
"$SCRIPT_DIR/venv/bin/python3" main.py
