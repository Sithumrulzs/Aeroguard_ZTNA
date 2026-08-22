#!/bin/bash
# =============================================================================
#  AeroGuard ZTNA — Dual-Port SPA Firewall Setup
#
#  Run ONCE as root before starting the gateway:
#      sudo bash setup_darkmode.sh
#
#  Optional overrides:
#      GATEWAY_INTERFACE=eth0  POCKET_SUBNET=10.0.0.0/24  sudo bash setup_darkmode.sh
#
#  What this does:
#    - Drops ALL inbound traffic by default (ping, nmap, SSH — everything)
#    - UDP 7777 and TCP 8000 explicitly dropped (invisible to scanners)
#    - Scapy sniffer still sees UDP 7777 via raw AF_PACKET socket (bypasses netfilter)
#    - Enables route_localnet + MASQUERADE so DNAT → 127.0.0.1:8000 works
#    - After a verified SPA knock, spa_sniffer.py injects per-IP ACCEPT + DNAT rules
# =============================================================================

POCKET_SUBNET="${POCKET_SUBNET:-192.168.100.0/24}"
# Auto-detect default interface if not overridden (handles eth0, wlan0, etc.)
GATEWAY_IFACE="${GATEWAY_INTERFACE:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"
GATEWAY_IFACE="${GATEWAY_IFACE:-eth0}"
# The "Aeroguard-internal" NIC facing the FIDS VM — auto-detected by which
# interface actually carries an IP on FIDS_HOST's /24, so this doesn't
# silently break if the guest ever renumbers past eth1.
FIDS_HOST="${FIDS_HOST:-10.66.100.150}"
FIDS_IFACE="${FIDS_INTERFACE:-$(ip -4 -o addr show 2>/dev/null | awk -v subnet="${FIDS_HOST%.*}." '$4 ~ "^"subnet {print $2; exit}')}"
FIDS_IFACE="${FIDS_IFACE:-eth1}"
KNOCK_PORT=8000
UDP_PORT=7777

if [ "$EUID" -ne 0 ]; then
    echo "[!] Run as root: sudo bash setup_darkmode.sh"
    exit 1
fi

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   AeroGuard ZTNA — SPA Firewall Setup           ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "  Interface     : $GATEWAY_IFACE"
echo "  FIDS iface    : $FIDS_IFACE ($FIDS_HOST)"
echo "  Pocket subnet : $POCKET_SUBNET"
echo "  SPA UDP port  : $UDP_PORT"
echo "  Gateway port  : $KNOCK_PORT"
echo ""

# ── 0. Disable ufw — conflicts with manual iptables rules ─────────────────────
if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "active"; then
        echo "[0/8] Disabling ufw..."
        ufw disable
    else
        echo "[0/8] ufw not active — skipping."
    fi
fi

# ── 1. Flush all tables cleanly ───────────────────────────────────────────────
echo "[1/8] Flushing all iptables rules..."
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD
iptables -t nat    -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t raw    -F 2>/dev/null || true
iptables -X           2>/dev/null || true

# ── 2. Default DROP policy ────────────────────────────────────────────────────
echo "[2/8] Setting default DROP policy..."
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# ── 3. Loopback — always allow ────────────────────────────────────────────────
echo "[3/8] Allowing loopback..."
iptables -A INPUT -i lo -j ACCEPT

# ── 4. Established/related return traffic ────────────────────────────────────
echo "[4/8] Allowing established/related return packets..."
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── 5. Explicit DROP for SPA ports (makes intent visible in iptables -L) ──────
# UDP 7777: Scapy sniffer reads it via raw socket BEFORE netfilter drops it.
# TCP 8000: blocked until spa_sniffer.py injects a per-IP ACCEPT + DNAT rule.
echo "[5/8] Explicitly dropping UDP $UDP_PORT and TCP $KNOCK_PORT..."
iptables -A INPUT -p udp --dport "$UDP_PORT"   -j DROP
iptables -A INPUT -p tcp --dport "$KNOCK_PORT" -j DROP

# ── 6. Enable DNAT + IP forwarding ───────────────────────────────────────────
# route_localnet: lets DNAT redirect to 127.0.0.1:8000 from external clients.
# ip_forward: kernel must forward packets between interfaces so that laptop
#             FORWARD rules injected by spa_sniffer.py actually take effect.
# MASQUERADE on outgoing iface: rewrites src IP for laptop → internet traffic.
echo "[6/8] Enabling route_localnet, ip_forward, and MASQUERADE..."
sysctl -w net.ipv4.conf.all.route_localnet=1 > /dev/null
sysctl -w net.ipv4.ip_forward=1              > /dev/null

# DNAT loopback rewrite for phone → FastAPI
iptables -t nat -A POSTROUTING \
    -d 127.0.0.1 -p tcp --dport "$KNOCK_PORT" -j MASQUERADE

# NAT for laptop traffic routed through Kali (ping, nmap, internet)
iptables -t nat -A POSTROUTING -o "$GATEWAY_IFACE" -j MASQUERADE

# NAT for laptop → FIDS traffic routed out the internal NIC. Without this,
# spa_sniffer.py's per-laptop DNAT to $FIDS_HOST:$FIDS_PORT forwards the
# packet with the laptop's own source IP intact — which FIDS's own ufw
# rule (ALLOW 3000/tcp FROM the gateway's internal IP only) then silently
# drops, since it never sees a source IP it trusts. MASQUERADE rewrites it
# to this gateway's own $FIDS_IFACE address, matching what FIDS expects.
iptables -t nat -A POSTROUTING -o "$FIDS_IFACE" -j MASQUERADE

# Allow return / established traffic through FORWARD chain (stateful)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── 7. Persist sysctl across reboots ─────────────────────────────────────────
echo "[7/8] Persisting sysctl settings..."
if ! grep -q "net.ipv4.conf.all.route_localnet" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.conf.all.route_localnet = 1" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi

# ── 8. Verify ─────────────────────────────────────────────────────────────────
echo "[8/8] Active INPUT chain:"
iptables -L INPUT -n --line-numbers
echo ""
echo "Active NAT PREROUTING chain:"
iptables -t nat -L PREROUTING -n --line-numbers

echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║   BLACKHOLE ACTIVE — Dual-Port SPA Ready        ║"
echo "  ╠══════════════════════════════════════════════════╣"
echo "  ║  nmap 192.168.100.130  → all ports filtered     ║"
echo "  ║  ping 192.168.100.130  → no reply (DROPPED)     ║"
echo "  ║  UDP 7777              → dropped (sniffer sees) ║"
echo "  ║  TCP 8000              → dropped until knock     ║"
echo "  ║  verified SPA knock    → ACCEPT + DNAT injected  ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "[*] Ready. Start the gateway:"
echo "    sudo bash start_gateway.sh"
