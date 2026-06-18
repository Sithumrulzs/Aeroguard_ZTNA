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

# Ensure conntrack CLI is available (needed to flush connection tracking on shutdown)
if ! command -v conntrack &>/dev/null; then
    echo "[*] Installing conntrack..."
    apt-get install -y -q conntrack 2>/dev/null
fi

# Step 1: Apply SPA firewall — flush all rules and enter dark mode
echo "[*] Step 1 — Applying SPA firewall (dark mode)..."
bash "$SCRIPT_DIR/setup_darkmode.sh"

# Step 2: Kill ALL leftover processes from any previous run, then start fresh
echo ""
echo "[*] Step 2 — Cleaning up previous run..."
pkill -9 -f "spa_sniffer.py"        2>/dev/null
pkill -9 -f "python3.*main\.py"     2>/dev/null
pkill -9 -f "uvicorn"               2>/dev/null
fuser  -k  8000/tcp                  2>/dev/null
sleep 1
echo "    Port 8000 status: $(ss -tlnp 2>/dev/null | grep 8000 || echo 'FREE')"

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
