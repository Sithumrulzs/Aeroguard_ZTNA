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

# Step 1: Apply SPA firewall (dark mode + DNAT support)
echo "[*] Step 1 — Applying SPA firewall..."
bash "$SCRIPT_DIR/setup_darkmode.sh"

# Step 2: Start SPA sniffer in background (must run as root for raw socket)
echo ""
echo "[*] Step 2 — Starting SPA knock sniffer (UDP 7777)..."
python3 -u "$SCRIPT_DIR/spa_sniffer.py" &
SNIFFER_PID=$!
echo "    sniffer PID: $SNIFFER_PID"

# Brief pause to let the sniffer bind before the gateway starts
sleep 1

# Step 3: Start FastAPI gateway on loopback (reachable only after a verified knock)
echo ""
echo "[*] Step 3 — Starting AeroGuard Gateway (127.0.0.1:8000)..."
echo ""
cd "$SCRIPT_DIR"
python3 main.py

# If FastAPI exits, kill the sniffer too
kill "$SNIFFER_PID" 2>/dev/null
