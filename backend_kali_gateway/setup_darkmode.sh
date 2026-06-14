#!/bin/bash
# =============================================================================
#  AeroGuard ZTNA — Dark Mode Network Setup
#  Run ONCE as root before starting the gateway:
#
#      sudo bash setup_darkmode.sh
#
#  Optional: override the pocket router subnet or interface:
#      POCKET_SUBNET=10.0.0.0/24 WIFI_INTERFACE=eth0 sudo bash setup_darkmode.sh
#
#  What this does:
#    - Drops ALL inbound traffic by default (ping, nmap, SSH — everything)
#    - Opens port 8000 only for devices on the pocket router subnet
#    - Allows Kali's own outbound traffic and return packets
#    - Every other port remains invisible (no response, not even RST)
#
#  After a verified ECDSA knock, main.py injects a timed ACCEPT rule for
#  the phone's IP with a 1-hour datestop. That rule is removed automatically
#  by the iptables time module — no daemon needed.
# =============================================================================

POCKET_SUBNET="${POCKET_SUBNET:-192.168.100.0/24}"
KNOCK_PORT=8000

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "[!] This script must be run as root."
    echo "    Usage: sudo bash setup_darkmode.sh"
    exit 1
fi

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   AeroGuard ZTNA — Dark Mode Network Setup      ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "  Pocket subnet : $POCKET_SUBNET"
echo "  Knock port    : $KNOCK_PORT"
echo ""

# ── 0. Disable ufw — it manages its own iptables chains and will override ours
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -1)
    if echo "$UFW_STATUS" | grep -q "active"; then
        echo "[0/6] Disabling ufw (conflicts with manual iptables)..."
        ufw disable
    else
        echo "[0/6] ufw not active — skipping."
    fi
fi

# ── 1. Flush ALL tables and chains cleanly ────────────────────────────────────
echo "[1/6] Flushing all iptables rules across all tables..."
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD
iptables -t nat    -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t raw    -F 2>/dev/null || true
iptables -X           2>/dev/null || true

# ── 2. Default DROP policy — the blackhole ────────────────────────────────────
echo "[2/6] Setting default DROP policy (blackhole)..."
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT    # Kali's own outbound is always unrestricted

# ── 3. Loopback — localhost must always work ──────────────────────────────────
echo "[3/6] Allowing loopback..."
iptables -A INPUT -i lo -j ACCEPT

# ── 4. Return traffic — use 'state' module (ships on every Kali kernel) ───────
# NOTE: 'conntrack' requires xt_conntrack which is not always loaded.
#       'state' (xt_state) is the older compatible form that always works.
echo "[4/6] Allowing established/related return packets..."
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── 5. Knock endpoint — subnet-restricted ─────────────────────────────────────
echo "[5/6] Opening knock endpoint (port $KNOCK_PORT) for $POCKET_SUBNET only..."
iptables -A INPUT -p tcp --dport "$KNOCK_PORT" -s "$POCKET_SUBNET" -j ACCEPT

# ── 6. Verify the chain looks right ───────────────────────────────────────────
echo "[6/6] Verifying active INPUT chain..."
iptables -L INPUT -n --line-numbers

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   BLACKHOLE ACTIVE — Gateway is now invisible    ║"
echo "  ╠══════════════════════════════════════════════════╣"
echo "  ║  ping 192.168.100.130    → no reply (DROPPED)   ║"
echo "  ║  nmap 192.168.100.130    → all ports filtered    ║"
echo "  ║  port 8000 (inside WiFi) → open for knock only   ║"
echo "  ║  unsigned knock attempt  → 403 (ECDSA rejected)  ║"
echo "  ║  verified knock          → ACCEPT rule injected  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "[*] Dark mode ready. Start the gateway:"
echo "    cd backend_kali_gateway && python main.py"
