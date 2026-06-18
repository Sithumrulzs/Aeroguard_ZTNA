"""
AeroGuard ZTNA — SPA Knock Sniffer

Two knock types:
  admin_knock  — ECDSA P-256 verified → opens tcp/GATEWAY_PORT for phone
                 + full network access for admin's registered laptop (MAC in DB)
  vendor_knock — QR token validated   → opens tcp/GATEWAY_PORT for phone
                 + 60-second window: first new device on network gets full access
                   for the session duration, then locked out on expiry
"""

import json
import hashlib
import subprocess
import threading
import signal
import atexit
import time
import os
from datetime import datetime, timezone
from contextlib import contextmanager
from dotenv import load_dotenv

import psycopg2
import psycopg2.extras
import ecdsa
from scapy.all import sniff, UDP, IP, Raw, ARP, Ether, srp, conf as scapy_conf, get_if_addr

# ── Environment ───────────────────────────────────────────────────────────────
load_dotenv()
DATABASE_URL    = os.getenv("DATABASE_URL")
UDP_KNOCK_PORT  = int(os.getenv("UDP_KNOCK_PORT",          "7777"))
GATEWAY_PORT    = int(os.getenv("GATEWAY_PORT",            "8000"))
SESSION_TIMEOUT = int(os.getenv("SESSION_TIMEOUT_SECONDS", "3600"))

_iface_env = os.getenv("GATEWAY_INTERFACE", "").strip()
IFACE       = _iface_env if _iface_env else str(scapy_conf.iface)
GATEWAY_IP  = os.getenv("GATEWAY_IP", "") or get_if_addr(IFACE)

if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL not set in .env")

# Active session timers keyed by IP (phones) or "laptop:<ip>" (laptops)
_timers: dict[str, threading.Timer] = {}
_lock   = threading.Lock()

# Track every IP we've injected so we can clean up on exit
_active_phones:  set[str] = set()
_active_laptops: set[str] = set()

# Map vendor token → IP so the revocation watcher can remove rules by token
_vendor_phone_map:  dict[str, str] = {}   # token_hash → phone_ip
_vendor_laptop_map: dict[str, str] = {}   # token_hash → laptop_ip


def _cleanup_all():
    """Remove every iptables rule this process injected. Called on exit."""
    print("\n[*] SHUTDOWN — flushing all injected firewall rules...")
    _vendor_phone_map.clear()
    _vendor_laptop_map.clear()
    for ip in list(_active_phones):
        _remove(ip)
    for ip in list(_active_laptops):
        _remove_laptop(ip)
    # Nuclear flush: wipe entire conntrack table so no ESTABLISHED/RELATED
    # state survives that could let removed IPs bypass the DEFAULT DROP policy.
    subprocess.run(["conntrack", "-F"], capture_output=True)
    print("[*] Firewall restored to dark mode.")


atexit.register(_cleanup_all)
signal.signal(signal.SIGTERM, lambda *_: exit(0))


# ── Database ──────────────────────────────────────────────────────────────────
@contextmanager
def get_db():
    conn = psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _log(event_type, username, status, ip, details):
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """INSERT INTO public.audit_logs
                       (event_type, username, client_ip, status, details, created_at)
                       VALUES (%s, %s, %s, %s, %s, %s)""",
                    (event_type, username, ip, status,
                     json.dumps(details), datetime.now(timezone.utc).isoformat())
                )
    except Exception as e:
        print(f"[-] Audit log failed: {e}")


# ── Phone firewall (port-specific) ────────────────────────────────────────────
def _inject(client_ip: str):
    """Open GATEWAY_PORT for phone IP: INPUT ACCEPT + PREROUTING DNAT to loopback."""
    subprocess.run(
        ["iptables", "-I", "INPUT", "1",
         "-s", client_ip, "-p", "tcp", "--dport", str(GATEWAY_PORT), "-j", "ACCEPT"],
        capture_output=True,
    )
    subprocess.run(
        ["iptables", "-t", "nat", "-I", "PREROUTING", "1",
         "-s", client_ip, "-p", "tcp", "--dport", str(GATEWAY_PORT),
         "-j", "DNAT", "--to-destination", f"127.0.0.1:{GATEWAY_PORT}"],
        capture_output=True,
    )
    _active_phones.add(client_ip)
    print(f"[+] RULES INJECTED  {client_ip} → tcp/{GATEWAY_PORT}")


def _flush_conntrack(ip: str):
    """Remove conntrack entries for an IP so ESTABLISHED/RELATED can't bypass DROP."""
    subprocess.run(["conntrack", "-D", "-s", ip], capture_output=True)
    subprocess.run(["conntrack", "-D", "-d", ip], capture_output=True)


def _remove(client_ip: str):
    """Remove phone's port-specific iptables rules."""
    subprocess.run(
        ["iptables", "-D", "INPUT",
         "-s", client_ip, "-p", "tcp", "--dport", str(GATEWAY_PORT), "-j", "ACCEPT"],
        capture_output=True,
    )
    subprocess.run(
        ["iptables", "-t", "nat", "-D", "PREROUTING",
         "-s", client_ip, "-p", "tcp", "--dport", str(GATEWAY_PORT),
         "-j", "DNAT", "--to-destination", f"127.0.0.1:{GATEWAY_PORT}"],
        capture_output=True,
    )
    _flush_conntrack(client_ip)
    _active_phones.discard(client_ip)
    print(f"[!] RULES REMOVED   {client_ip} phone session expired")


def _schedule(client_ip: str, timeout: int, username: str):
    """Schedule removal of phone session rules."""
    with _lock:
        existing = _timers.pop(client_ip, None)
        if existing:
            existing.cancel()

        def _expire():
            _remove(client_ip)
            _log("SESSION_EXPIRED", username, "EXPIRED", client_ip,
                 {"timeout_seconds": timeout})
            with _lock:
                _timers.pop(client_ip, None)

        t = threading.Timer(timeout, _expire)
        t.daemon = True
        t.start()
        _timers[client_ip] = t


# ── Laptop firewall (full access) ─────────────────────────────────────────────
def _inject_laptop(laptop_ip: str):
    """Grant full network access for a laptop — INPUT (to Kali) + FORWARD (through Kali)."""
    # Traffic destined TO Kali itself (ssh, api, etc.)
    subprocess.run(
        ["iptables", "-I", "INPUT", "1", "-s", laptop_ip, "-j", "ACCEPT"],
        capture_output=True,
    )
    # Traffic FROM laptop routed THROUGH Kali to other hosts / internet
    subprocess.run(
        ["iptables", "-I", "FORWARD", "1", "-s", laptop_ip, "-j", "ACCEPT"],
        capture_output=True,
    )
    # Return traffic back TO the laptop from those hosts
    subprocess.run(
        ["iptables", "-I", "FORWARD", "1", "-d", laptop_ip, "-j", "ACCEPT"],
        capture_output=True,
    )
    _active_laptops.add(laptop_ip)
    print(f"[+] LAPTOP ACCESS   {laptop_ip} — full access granted (ping/nmap enabled)")


def _remove_laptop(laptop_ip: str):
    """Revoke full network access for a laptop."""
    subprocess.run(
        ["iptables", "-D", "INPUT", "-s", laptop_ip, "-j", "ACCEPT"],
        capture_output=True,
    )
    subprocess.run(
        ["iptables", "-D", "FORWARD", "-s", laptop_ip, "-j", "ACCEPT"],
        capture_output=True,
    )
    subprocess.run(
        ["iptables", "-D", "FORWARD", "-d", laptop_ip, "-j", "ACCEPT"],
        capture_output=True,
    )
    _flush_conntrack(laptop_ip)
    _active_laptops.discard(laptop_ip)
    print(f"[!] LAPTOP REMOVED  {laptop_ip} — session expired")


def _schedule_laptop(laptop_ip: str, timeout: int, name: str):
    """Schedule removal of laptop full-access rules."""
    key = f"laptop:{laptop_ip}"
    with _lock:
        existing = _timers.pop(key, None)
        if existing:
            existing.cancel()

        def _expire():
            _remove_laptop(laptop_ip)
            _log("LAPTOP_EXPIRED", name, "EXPIRED", laptop_ip,
                 {"timeout_seconds": timeout})
            with _lock:
                _timers.pop(key, None)

        t = threading.Timer(timeout, _expire)
        t.daemon = True
        t.start()
        _timers[key] = t


# ── MAC → IP resolution ───────────────────────────────────────────────────────
def _mac_to_ip(mac: str) -> str | None:
    """
    Resolve a MAC address to an IP by doing a live ARP scan of the subnet.
    Scapy ARP is reliable because every device MUST reply to ARP requests
    (unlike broadcast ICMP, which Windows ignores by default).
    """
    if not mac:
        return None
    mac_clean = mac.lower().replace("-", ":")
    subnet = ".".join(GATEWAY_IP.split(".")[:3]) + ".0/24"
    try:
        answered, _ = srp(
            Ether(dst="ff:ff:ff:ff:ff:ff") / ARP(pdst=subnet),
            iface=IFACE, timeout=4, verbose=0,
        )
        for _, rcv in answered:
            if rcv[Ether].src.lower() == mac_clean:
                return rcv[ARP].psrc
    except Exception as e:
        print(f"[-] ARP scan failed: {e}")
    return None


# ── Vendor device watcher (pending-approval flow) ─────────────────────────────
def _store_pending_device(token_hash: str, device_ip: str, device_mac: str):
    """Store detected device as pending in vendor_sessions for admin review."""
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """UPDATE public.vendor_sessions
                       SET pending_device_ip  = %s,
                           pending_device_mac = %s,
                           device_approved    = FALSE
                       WHERE qr_token = %s""",
                    (device_ip, device_mac, token_hash)
                )
    except Exception as e:
        print(f"[-] Store pending device failed: {e}")


def _poll_for_approval(token_hash: str, vendor_name: str,
                       device_ip: str, session_timeout: int):
    """
    Poll DB every 3 seconds until admin approves or session expires.
    On approval: inject FORWARD rules for the device IP.
    """
    deadline = time.time() + session_timeout

    def _poll():
        while time.time() < deadline:
            time.sleep(3)
            try:
                with get_db() as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            """SELECT device_approved, pending_device_ip, status
                               FROM public.vendor_sessions
                               WHERE qr_token = %s""",
                            (token_hash,)
                        )
                        row = cur.fetchone()
            except Exception as e:
                print(f"[-] Approval poll DB error: {e}")
                continue

            if not row:
                break

            if row["status"] in ("expired", "revoked"):
                print(f"[-] APPROVAL POLL  {vendor_name} — session {row['status']}")
                break

            if row["device_approved"]:
                approved_ip = row["pending_device_ip"] or device_ip
                remaining   = max(int(deadline - time.time()), 60)
                _inject_laptop(approved_ip)
                _vendor_laptop_map[token_hash] = approved_ip
                _schedule_laptop(approved_ip, remaining, vendor_name)
                _log("VENDOR_DEVICE", vendor_name, "APPROVED", approved_ip,
                     {"token": token_hash[:12] + "...", "remaining_seconds": remaining})
                print(f"[+] DEVICE APPROVED {vendor_name} → {approved_ip} — full access granted ({remaining}s)")
                break
        else:
            print(f"[-] APPROVAL POLL  {vendor_name} — timed out without approval")

    threading.Thread(target=_poll, daemon=True).start()
    print(f"[*] APPROVAL POLL  {vendor_name} — waiting for admin decision on {device_ip}")


def _watch_vendor_device(vendor_name: str, phone_ip: str,
                         session_timeout: int, token_hash: str):
    """
    Opens a 60-second detection window after a vendor knock.
    The first NEW device that sends any packet is stored as pending_device
    in the DB for admin approval. Admin approves via the app; the sniffer's
    _poll_for_approval thread then injects FORWARD rules for that device.
    """
    registered = threading.Event()
    already_active = frozenset(_active_laptops)

    def _on_pkt(pkt):
        if registered.is_set():
            return True
        if not (IP in pkt):
            return
        src_ip = pkt[IP].src
        if (src_ip == phone_ip or src_ip == GATEWAY_IP
                or src_ip in already_active
                or src_ip.endswith(".255") or src_ip.startswith("224.")
                or src_ip.startswith("239.")):
            return
        device_mac = pkt[Ether].src if Ether in pkt else ""
        registered.set()
        _store_pending_device(token_hash, src_ip, device_mac)
        _log("VENDOR_DEVICE_PENDING", vendor_name, "PENDING_APPROVAL", src_ip,
             {"mac": device_mac, "token": token_hash[:12] + "..."})
        print(f"[*] DEVICE PENDING  {vendor_name} → {src_ip} ({device_mac}) — awaiting admin approval")
        _poll_for_approval(token_hash, vendor_name, src_ip, session_timeout)
        return True

    def _run_sniff():
        sniff(
            iface=IFACE,
            filter=f"ip and dst host {GATEWAY_IP} and not src host {phone_ip}",
            prn=_on_pkt,
            timeout=60,
            stop_filter=lambda x: registered.is_set(),
        )
        if not registered.is_set():
            print(f"[-] VENDOR WINDOW   {vendor_name} — no device detected in 60s")

    threading.Thread(target=_run_sniff, daemon=True).start()
    print(f"[*] VENDOR WINDOW   {vendor_name} — 60s detection window open")


# ── ECDSA verification ────────────────────────────────────────────────────────
def _verify_ecdsa(public_key_hex: str, raw_payload: str, signature_hex: str) -> bool:
    try:
        key = bytes.fromhex(public_key_hex)
        if len(key) == 65 and key[0] == 0x04:
            key = key[1:]
        vk = ecdsa.VerifyingKey.from_string(key, curve=ecdsa.NIST256p)
        h  = hashlib.sha256(raw_payload.encode()).digest()
        try:
            return vk.verify_digest(bytes.fromhex(signature_hex), h)
        except Exception:
            return vk.verify_digest(bytes.fromhex(signature_hex), h,
                                    sigdecode=ecdsa.util.sigdecode_der)
    except Exception as e:
        print(f"[-] ECDSA error: {e}")
        return False


# ── Knock handlers ────────────────────────────────────────────────────────────
def _admin_knock(ip: str, d: dict):
    username  = d.get("username",  "").strip()
    device_id = d.get("device_id", "")
    ts        = d.get("timestamp", "")
    sig       = d.get("signature", "")

    print(f"[*] ADMIN KNOCK   {username} @ {ip}")

    # Anti-replay: reject packets older than 60 seconds
    try:
        age = abs((datetime.now(timezone.utc) -
                   datetime.fromisoformat(ts.replace("Z", "+00:00"))
                   ).total_seconds())
        if age > 60:
            print(f"[-] REPLAY        {username} — {age:.0f}s old")
            _log("ZTNA_KNOCK", username, "DENIED - REPLAY", ip, {"age_seconds": age})
            return
    except Exception:
        print(f"[-] BAD TIMESTAMP {username}")
        return

    # DB lookup — fetch key + laptop MAC
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT public_key_pem, is_active, laptop_mac "
                    "FROM public.users WHERE username = %s",
                    (username,)
                )
                user = cur.fetchone()
    except Exception as e:
        print(f"[-] DB error: {e}")
        return

    if not user:
        _log("ZTNA_KNOCK", username, "DENIED - NOT FOUND", ip, {})
        return
    if not user["is_active"]:
        _log("ZTNA_KNOCK", username, "DENIED - INACTIVE", ip, {})
        return

    pub = (user["public_key_pem"] or "").strip()
    if pub in {"dummy_key_until_flutter_is_connected", "dummy_key_until_scanned",
               "manual_admin_provision", "pending", ""}:
        _log("ZTNA_KNOCK", username, "DENIED - NO KEY", ip,
             {"reason": "Device not registered"})
        return

    # ECDSA verification
    if not _verify_ecdsa(pub, f"{device_id}:{username}:{ts}", sig):
        print(f"[-] BAD SIGNATURE {username}")
        _log("ZTNA_KNOCK", username, "DENIED - BAD SIGNATURE", ip,
             {"device_id": device_id})
        return

    # ── Grant phone access to GATEWAY_PORT ───────────────────────────────────
    _inject(ip)
    _schedule(ip, SESSION_TIMEOUT, username)
    _log("ZTNA_KNOCK", username, "GRANTED", ip,
         {"device_id": device_id, "session_seconds": SESSION_TIMEOUT})
    print(f"[+] GRANTED       {username} — {SESSION_TIMEOUT}s session open")

    # ── Grant laptop full access via registered MAC ───────────────────────────
    laptop_mac = (user.get("laptop_mac") or "").strip()
    if laptop_mac:
        laptop_ip = _mac_to_ip(laptop_mac)
        if laptop_ip:
            _inject_laptop(laptop_ip)
            _schedule_laptop(laptop_ip, SESSION_TIMEOUT, username)
            _log("LAPTOP_ACCESS", username, "GRANTED", laptop_ip,
                 {"mac": laptop_mac, "session_seconds": SESSION_TIMEOUT})
            print(f"[+] LAPTOP GRANTED  {username} → {laptop_ip} ({laptop_mac})")
        else:
            print(f"[!] LAPTOP OFFLINE  {username} — MAC {laptop_mac} not found in ARP")
    else:
        print(f"[!] NO LAPTOP MAC   {username} — set laptop_mac in DB to enable laptop access")


def _vendor_knock(ip: str, d: dict):
    token_hash  = d.get("token_hash",  "")
    vendor_name = d.get("vendor_name", "")

    print(f"[*] VENDOR KNOCK  {vendor_name} @ {ip}")

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT * FROM public.vendor_sessions "
                    "WHERE qr_token = %s AND status NOT IN ('expired', 'revoked')",
                    (token_hash,)
                )
                session = cur.fetchone()
    except Exception as e:
        print(f"[-] DB error: {e}")
        return

    if not session:
        _log("VENDOR_KNOCK", vendor_name, "DENIED - INVALID TOKEN", ip,
             {"hash": token_hash[:16] + "..."})
        return

    try:
        expiry  = datetime.fromisoformat(
            str(session["valid_until"]).replace("Z", "+00:00"))
        if datetime.now(timezone.utc) > expiry:
            _log("VENDOR_KNOCK", vendor_name, "DENIED - EXPIRED", ip, {})
            return
        timeout = max(int((expiry - datetime.now(timezone.utc)).total_seconds()), 0)
    except Exception:
        return

    # ── Grant phone access to GATEWAY_PORT ───────────────────────────────────
    _inject(ip)
    _vendor_phone_map[token_hash] = ip
    _schedule(ip, timeout, vendor_name)
    _log("VENDOR_KNOCK_SPA", vendor_name, "GRANTED", ip,
         {"company": session["company_name"], "session_seconds": timeout})
    print(f"[+] GRANTED       {vendor_name} — {timeout}s session open")

    # ── Start 60-second window for vendor laptop detection ────────────────────
    _watch_vendor_device(vendor_name, ip, timeout, token_hash)


# ── Scapy packet handler ──────────────────────────────────────────────────────
def _on_packet(pkt):
    if not (IP in pkt and UDP in pkt and Raw in pkt):
        return
    if pkt[UDP].dport != UDP_KNOCK_PORT:
        return

    client_ip = pkt[IP].src
    try:
        data = json.loads(pkt[Raw].load.decode("utf-8", errors="ignore").strip())
    except Exception:
        print(f"[-] Malformed packet from {client_ip}")
        return

    if data.get("type") == "vendor_knock":
        _vendor_knock(client_ip, data)
    else:
        _admin_knock(client_ip, data)


# ── Vendor session revocation watcher ────────────────────────────────────────
def _revocation_watcher():
    """Poll DB every 20s for vendor sessions manually revoked by admin.
    Cancels the session timer and removes iptables + conntrack rules immediately
    so access is cut before the natural expiry timer fires."""
    while True:
        time.sleep(20)
        if not _vendor_phone_map:
            continue
        try:
            tokens = list(_vendor_phone_map.keys())
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """SELECT qr_token FROM public.vendor_sessions
                           WHERE status IN ('revoked', 'expired')
                             AND qr_token = ANY(%s)""",
                        (tokens,)
                    )
                    revoked_tokens = [r["qr_token"] for r in cur.fetchall()]
        except Exception as e:
            print(f"[-] Revocation watcher DB error: {e}")
            continue

        for token in revoked_tokens:
            phone_ip  = _vendor_phone_map.pop(token, None)
            laptop_ip = _vendor_laptop_map.pop(token, None)

            if phone_ip and phone_ip in _active_phones:
                with _lock:
                    t = _timers.pop(phone_ip, None)
                    if t:
                        t.cancel()
                _remove(phone_ip)
                print(f"[!] VENDOR REVOKED  phone {phone_ip} — admin cut access")

            if laptop_ip and laptop_ip in _active_laptops:
                with _lock:
                    t = _timers.pop(f"laptop:{laptop_ip}", None)
                    if t:
                        t.cancel()
                _remove_laptop(laptop_ip)
                print(f"[!] VENDOR REVOKED  laptop {laptop_ip} — admin cut access")


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    threading.Thread(target=_revocation_watcher, daemon=True).start()
    print("\n" + "=" * 60)
    print(f"AeroGuard SPA Sniffer  —  UDP {UDP_KNOCK_PORT} on {IFACE}")
    print(f"Gateway IP   : {GATEWAY_IP}")
    print(f"Gateway port : {GATEWAY_PORT}  |  Session TTL : {SESSION_TIMEOUT}s")
    print("=" * 60 + "\n")
    sniff(
        iface=IFACE,
        filter=f"udp port {UDP_KNOCK_PORT}",
        prn=_on_packet,
        store=False,
    )
