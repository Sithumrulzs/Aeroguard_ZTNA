"""
AeroGuard ZTNA — Kali Gateway  (data-logging layer)
Bound to 127.0.0.1 — only reachable after a verified SPA knock via DNAT.
Firewall enforcement is handled exclusively by spa_sniffer.py.
"""

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from datetime import datetime, timezone
from contextlib import contextmanager
from dotenv import load_dotenv
import psycopg2
import psycopg2.extras
import subprocess
import json
import os
import uvicorn

# ── Environment ───────────────────────────────────────────────────────────────
load_dotenv()
DATABASE_URL  = os.getenv("DATABASE_URL")
PORT          = int(os.getenv("PORT",          "8000"))
GATEWAY_PORT  = int(os.getenv("GATEWAY_PORT",  "8000"))
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL not set. Check backend_kali_gateway/.env")

app = FastAPI(title="AeroGuard ZTNA Gateway")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


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


# ── Models ────────────────────────────────────────────────────────────────────
class KnockLogPayload(BaseModel):
    device_id: str
    username:  str
    timestamp: str
    signature: str
    telemetry: dict = {}

class VendorProvisionPayload(BaseModel):
    token_hash:      str
    vendor_name:     str
    company:         str
    clearance_level: str = "standard"
    target_device:   str = ""
    valid_until:     str

class VendorKnockPayload(BaseModel):
    token_hash:  str
    vendor_name: str
    latitude:    float | None = None
    longitude:   float | None = None

class RevokeAdminPayload(BaseModel):
    username: str


# ── Helpers ───────────────────────────────────────────────────────────────────
def log_audit(event_type: str, username: str, status: str,
              ip: str, details: dict):
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


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.post("/api/v1/knock")
async def admin_knock_log(payload: KnockLogPayload, request: Request):
    """
    Called by Flutter AFTER the SPA sniffer has already verified the ECDSA
    knock and opened port 8000 for this IP. Role: write the granted session
    to audit_logs only. No crypto or firewall work happens here.
    """
    client_ip = request.client.host
    log_audit("ZTNA_KNOCK", payload.username, "GRANTED", client_ip,
              {"device_id": payload.device_id, "via": "spa_sniffer"})
    print(f"[+] ADMIN SESSION LOGGED: {payload.username} @ {client_ip}")
    return {"status": "success", "message": "Access granted."}


@app.post("/api/v1/provision-vendor")
async def provision_vendor(payload: VendorProvisionPayload, request: Request):
    try:
        expiry = datetime.fromisoformat(payload.valid_until.replace("Z", "+00:00"))
        if expiry <= datetime.now(timezone.utc):
            raise HTTPException(status_code=400,
                                detail="valid_until must be a future timestamp.")
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid valid_until format.")

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id FROM public.vendor_sessions WHERE qr_token = %s",
                    (payload.token_hash,)
                )
                if cur.fetchone():
                    raise HTTPException(status_code=409,
                                        detail="Token already provisioned.")
                cur.execute(
                    """INSERT INTO public.vendor_sessions
                       (qr_token, vendor_username, company_name,
                        clearance_level, status, valid_until)
                       VALUES (%s, %s, %s, %s, 'pending', %s)""",
                    (payload.token_hash, payload.vendor_name, payload.company,
                     payload.clearance_level, payload.valid_until)
                )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Provision failed: {e}")

    log_audit("VENDOR_PROVISION", payload.vendor_name, "PROVISIONED",
              request.client.host,
              {"company": payload.company, "valid_until": payload.valid_until})
    print(f"[+] VENDOR PROVISIONED: {payload.vendor_name} | expires {payload.valid_until}")
    return {
        "status":     "success",
        "message":    f"Vendor session provisioned for {payload.vendor_name}.",
        "valid_until": payload.valid_until,
    }


@app.post("/api/v1/vendor_knock")
async def vendor_knock(payload: VendorKnockPayload, request: Request):
    """
    Called by the vendor app AFTER the SPA sniffer has opened port 8000.
    Handles Trust-on-First-Knock IP binding, session details, and GPS update.
    Firewall rule injection is done by the sniffer, not here.
    """
    client_ip = request.client.host

    # 1. Session lookup
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT * FROM public.vendor_sessions "
                    "WHERE qr_token = %s AND status != 'expired'",
                    (payload.token_hash,)
                )
                session = cur.fetchone()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    if not session:
        log_audit("VENDOR_KNOCK", payload.vendor_name, "DENIED - INVALID TOKEN",
                  client_ip, {"hash": payload.token_hash})
        raise HTTPException(status_code=403,
                            detail="Invalid or inactive vendor token.")

    valid_until = session["valid_until"]

    # 2. Expiry check
    try:
        expiry = datetime.fromisoformat(str(valid_until).replace("Z", "+00:00"))
        if datetime.now(timezone.utc) > expiry:
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE public.vendor_sessions SET status = 'expired' "
                        "WHERE qr_token = %s",
                        (payload.token_hash,)
                    )
            log_audit("VENDOR_KNOCK", payload.vendor_name,
                      "DENIED - SESSION EXPIRED", client_ip,
                      {"valid_until": str(valid_until)})
            raise HTTPException(status_code=403, detail="Vendor session has expired.")
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="Corrupt session timestamp.")

    # 3. Trust-on-First-Knock — bind vendor IP on first use
    vendor_db_username = session["vendor_username"]
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT locked_mac FROM public.users WHERE username = %s",
                    (vendor_db_username,)
                )
                user = cur.fetchone()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    locked_mac = (user["locked_mac"] if user else "") or ""

    if not locked_mac.strip():
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE public.users SET locked_mac = %s WHERE username = %s",
                    (client_ip, vendor_db_username)
                )
                cur.execute(
                    "UPDATE public.vendor_sessions SET status = 'active' "
                    "WHERE qr_token = %s",
                    (payload.token_hash,)
                )
        locked_mac = client_ip
        print(f"[+] VENDOR FIRST KNOCK: {client_ip} bound to {payload.vendor_name}")
    elif client_ip != locked_mac:
        log_audit("VENDOR_KNOCK", payload.vendor_name, "DENIED - DEVICE MISMATCH",
                  client_ip, {"bound_ip": locked_mac, "attempted_ip": client_ip})
        raise HTTPException(status_code=403,
                            detail="Device mismatch. Session locked to a different machine.")

    # 4. GPS update
    if payload.latitude is not None and payload.longitude is not None:
        try:
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """UPDATE public.vendor_sessions
                           SET last_seen_lat = %s, last_seen_lng = %s,
                               last_seen_at  = %s
                           WHERE qr_token = %s""",
                        (payload.latitude, payload.longitude,
                         datetime.now(timezone.utc).isoformat(),
                         payload.token_hash)
                    )
        except Exception as e:
            print(f"[!] Vendor location update skipped: {e}")

    log_audit("VENDOR_KNOCK", payload.vendor_name, "GRANTED", client_ip,
              {"company":   session["company_name"],
               "clearance": session["clearance_level"],
               "latitude":  payload.latitude,
               "longitude": payload.longitude})

    return {
        "status":      "success",
        "message":     "Vendor tunnel authorised.",
        "role":        "vendor",
        "vendor_name": payload.vendor_name,
        "company":     session["company_name"],
        "valid_until": str(valid_until),
        "bound_ip":    client_ip,
    }


@app.post("/api/v1/revoke-admin-session")
async def revoke_admin_session(payload: RevokeAdminPayload, request: Request):
    """
    Called by the admin app when the knock button is tapped while connected.
    Removes the admin phone's port-specific rules AND the laptop's full-access
    rules from iptables, then flushes conntrack so the DROP policy takes effect
    immediately with no ESTABLISHED/RELATED bypass.
    """
    phone_ip = request.client.host

    # ── Phone rules ───────────────────────────────────────────────────────────
    subprocess.run(
        ["iptables", "-D", "INPUT", "-s", phone_ip, "-p", "tcp",
         "--dport", str(GATEWAY_PORT), "-j", "ACCEPT"],
        capture_output=True,
    )
    subprocess.run(
        ["iptables", "-t", "nat", "-D", "PREROUTING", "-s", phone_ip,
         "-p", "tcp", "--dport", str(GATEWAY_PORT),
         "-j", "DNAT", "--to-destination", f"127.0.0.1:{GATEWAY_PORT}"],
        capture_output=True,
    )

    # ── Laptop rules — look up most recent LAPTOP_ACCESS grant ───────────────
    laptop_ip = None
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """SELECT client_ip FROM public.audit_logs
                       WHERE event_type = 'LAPTOP_ACCESS'
                         AND username   = %s
                         AND status     = 'GRANTED'
                       ORDER BY created_at DESC LIMIT 1""",
                    (payload.username,)
                )
                row = cur.fetchone()
        if row:
            laptop_ip = row["client_ip"]
    except Exception as e:
        print(f"[-] Revoke — DB lookup failed: {e}")

    if laptop_ip:
        subprocess.run(
            ["iptables", "-D", "INPUT",   "-s", laptop_ip, "-j", "ACCEPT"],
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
        subprocess.run(["conntrack", "-D", "-s", laptop_ip], capture_output=True)
        subprocess.run(["conntrack", "-D", "-d", laptop_ip], capture_output=True)

    subprocess.run(["conntrack", "-D", "-s", phone_ip], capture_output=True)
    subprocess.run(["conntrack", "-D", "-d", phone_ip], capture_output=True)

    log_audit("ADMIN_REVOKE", payload.username, "REVOKED", phone_ip,
              {"laptop_ip": laptop_ip, "via": "manual_close"})
    print(f"[!] ADMIN REVOKED  {payload.username} @ {phone_ip}"
          f"{f' | laptop {laptop_ip}' if laptop_ip else ''}")

    return {"status": "revoked", "phone_ip": phone_ip, "laptop_ip": laptop_ip}


@app.get("/api/v1/network/scan")
def scan_network_devices():
    """
    ARP-scan the local subnet and return every live device.
    Uses the kernel ARP cache (/proc/net/arp) — fast, root-only, no extra tools.
    Only complete entries (flag 0x2) are returned so stale MACs are excluded.
    """
    devices = []
    try:
        with open("/proc/net/arp") as f:
            for line in f.readlines()[1:]:          # skip header row
                parts = line.split()
                if len(parts) < 4:
                    continue
                ip, flags, mac = parts[0], parts[2], parts[3]
                if flags == "0x2" and mac != "00:00:00:00:00:00" \
                        and not ip.startswith("127."):
                    devices.append({"ip": ip, "mac": mac})
    except Exception as e:
        print(f"[-] Network scan error: {e}")
    return {"devices": devices, "count": len(devices)}


@app.get("/health")
async def health_check():
    return {"status": "ok", "service": "AeroGuard ZTNA Gateway"}


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print(f"AeroGuard ZTNA Gateway — 127.0.0.1:{PORT}")
    print("Firewall: spa_sniffer.py  |  Bound: loopback only")
    print("=" * 60 + "\n")
    uvicorn.run("main:app", host="127.0.0.1", port=PORT, reload=False)
