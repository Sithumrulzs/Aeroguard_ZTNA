"""
AeroGuard ZTNA — Kali Gateway Server
Sole responsibility: enforce network access via iptables.
Connects directly to the Supabase PostgreSQL database via psycopg2.
Credentials are loaded from .env — never hardcoded.
"""

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from datetime import datetime, timezone
from contextlib import asynccontextmanager, contextmanager
from dotenv import load_dotenv
import asyncio
import psycopg2
import psycopg2.extras
import ecdsa
import hashlib
import json
import os
import subprocess
import uvicorn

# ── Load environment ──────────────────────────────────────────────────────────
load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
PORT         = int(os.getenv("PORT", "8000"))
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL not set. Check backend_kali_gateway/.env")

async def _expire_vendor_sessions():
    """Background loop: every 30 s, terminate timed-out or admin-revoked sessions."""
    while True:
        await asyncio.sleep(30)
        now = datetime.now(timezone.utc)
        try:
            with get_db() as conn:
                with conn.cursor() as cur:
                    # Collect sessions to terminate:
                    # 1. Active sessions past their valid_until  (time expiry)
                    # 2. Sessions marked 'revoked' by an admin   (manual revoke)
                    cur.execute(
                        """SELECT vs.qr_token, vs.vendor_username, vs.valid_until,
                                  vs.status, u.locked_mac
                           FROM public.vendor_sessions vs
                           LEFT JOIN public.users u ON u.username = vs.vendor_username
                           WHERE (vs.status = 'active' AND vs.valid_until < %s)
                              OR  vs.status = 'revoked'""",
                        (now.isoformat(),)
                    )
                    to_terminate = cur.fetchall()

                    for s in to_terminate:
                        token  = s["qr_token"]
                        ip     = (s["locked_mac"] or "").strip()
                        ts     = str(s["valid_until"])
                        reason = "expired" if s["status"] == "active" else "revoked"

                        # Mark session as expired (final state for both paths)
                        cur.execute(
                            "UPDATE public.vendor_sessions SET status = 'expired' WHERE qr_token = %s",
                            (token,)
                        )

                        # Remove iptables rule if the vendor had an active IP bound
                        if ip:
                            try:
                                datestop = datetime.fromisoformat(
                                    ts.replace("Z", "+00:00")
                                ).strftime("%Y-%m-%dT%H:%M:%S")
                                subprocess.run(
                                    ["sudo", "iptables", "-D", "INPUT",
                                     "-s", ip, "-m", "time",
                                     "--datestop", datestop, "--utc", "-j", "ACCEPT"],
                                    check=False, capture_output=True,
                                )
                                # Also drop any simple ACCEPT rules added on first knock
                                subprocess.run(
                                    ["sudo", "iptables", "-D", "INPUT", "-s", ip, "-j", "ACCEPT"],
                                    check=False, capture_output=True,
                                )
                            except Exception:
                                pass

                        print(f"[!] VENDOR SESSION {reason.upper()}: {s['vendor_username']} | IP: {ip}")
                        log_audit(f"VENDOR_SESSION_{reason.upper()}", s["vendor_username"],
                                  reason.upper(), ip or "unknown",
                                  {"token": token[:16] + "...", "valid_until": ts})
        except Exception as e:
            print(f"[-] Session expiry check failed: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_expire_vendor_sessions())
    print("[*] Vendor session expiry monitor started (30 s interval)")
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="AeroGuard ZTNA Gateway", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Database connection ───────────────────────────────────────────────────────
@contextmanager
def get_db():
    """Context manager that yields a psycopg2 connection with RealDictCursor."""
    conn = psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# ── Pydantic models ───────────────────────────────────────────────────────────
class TelemetryPayload(BaseModel):
    device_id: str
    username:  str
    timestamp: str
    signature: str
    telemetry: dict

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


# ── Helpers ───────────────────────────────────────────────────────────────────
def verify_ecdsa_signature(public_key_hex: str, raw_payload: str,
                            signature_hex: str) -> bool:
    try:
        vk = ecdsa.VerifyingKey.from_string(
            bytes.fromhex(public_key_hex), curve=ecdsa.NIST256p
        )
        msg_hash = hashlib.sha256(raw_payload.encode()).digest()
        try:
            return vk.verify_digest(bytes.fromhex(signature_hex), msg_hash)
        except Exception:
            return vk.verify_digest(
                bytes.fromhex(signature_hex), msg_hash,
                sigdecode=ecdsa.util.sigdecode_der,
            )
    except Exception as e:
        print(f"[-] Crypto validation failed: {e}")
        return False


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
async def admin_knock(payload: TelemetryPayload, request: Request):
    print(f"\n[*] ADMIN KNOCK FROM: {payload.username}")
    client_ip = request.client.host

    # [BYPASS MODE] DB lookup, ECDSA verification, and audit log are temporarily
    # disabled. The knock is accepted for any authenticated user regardless of
    # device registration or cryptographic state.
    print(f"[BYPASS] Skipping DB lookup and signature check for {payload.username}")

    # Firewall — open the client IP (non-fatal if iptables is unavailable)
    subprocess.run(["sudo", "iptables", "-I", "INPUT", "1",
                    "-s", client_ip, "-j", "ACCEPT"],
                   check=False, capture_output=True)
    print(f"[ZTNA] Firewall rule attempted for {client_ip}")

    return {"status": "success", "message": "Access granted. Port knocked successfully."}


@app.post("/api/v1/provision-vendor")
async def provision_vendor(payload: VendorProvisionPayload, request: Request):
    try:
        expiry = datetime.fromisoformat(payload.valid_until.replace("Z", "+00:00"))
        if expiry <= datetime.now(timezone.utc):
            raise HTTPException(status_code=400, detail="valid_until must be a future timestamp.")
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid valid_until format.")

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id FROM public.vendor_sessions WHERE qr_token = %s",
                            (payload.token_hash,))
                if cur.fetchone():
                    raise HTTPException(status_code=409, detail="Token already provisioned.")

                cur.execute(
                    """INSERT INTO public.vendor_sessions
                       (qr_token, vendor_username, company_name, clearance_level, status, valid_until)
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
    return {"status": "success",
            "message": f"Vendor session provisioned for {payload.vendor_name}.",
            "valid_until": payload.valid_until}


@app.post("/api/v1/vendor_knock")
async def vendor_knock(payload: VendorKnockPayload, request: Request):
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
        raise HTTPException(status_code=403, detail="Invalid or inactive vendor token.")

    valid_until = session["valid_until"]

    # 2. Expiry check
    try:
        expiry = datetime.fromisoformat(str(valid_until).replace("Z", "+00:00"))
        if datetime.now(timezone.utc) > expiry:
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute("UPDATE public.vendor_sessions SET status = 'expired' WHERE qr_token = %s",
                                (payload.token_hash,))
            log_audit("VENDOR_KNOCK", payload.vendor_name, "DENIED - SESSION EXPIRED",
                      client_ip, {"valid_until": str(valid_until)})
            raise HTTPException(status_code=403, detail="Vendor session has expired.")
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="Corrupt session timestamp.")

    # 3. Hardware footprint (Trust-on-First-Knock)
    # Use vendor_username from the session row (DB key) not the display name.
    vendor_db_username = session["vendor_username"]
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT locked_mac FROM public.users WHERE username = %s",
                            (vendor_db_username,))
                user = cur.fetchone()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    locked_mac = (user["locked_mac"] if user else "") or ""

    if not locked_mac.strip():
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE public.users SET locked_mac = %s WHERE username = %s",
                            (client_ip, vendor_db_username))
                cur.execute("UPDATE public.vendor_sessions SET status = 'active' WHERE qr_token = %s",
                            (payload.token_hash,))
        locked_mac = client_ip
        print(f"[+] VENDOR FIRST KNOCK: {client_ip} bound to {payload.vendor_name}")
    elif client_ip != locked_mac:
        log_audit("VENDOR_KNOCK", payload.vendor_name, "DENIED - DEVICE MISMATCH",
                  client_ip, {"bound_ip": locked_mac, "attempted_ip": client_ip})
        raise HTTPException(status_code=403,
                            detail="Device mismatch. Session locked to a different machine.")

    # 4. Firewall with time expiry
    datestop = expiry.strftime("%Y-%m-%dT%H:%M:%S")
    subprocess.run(
        ["sudo", "iptables", "-I", "INPUT", "1", "-s", client_ip,
         "-m", "time", "--datestop", datestop, "--utc", "-j", "ACCEPT"],
        check=False, capture_output=True
    )
    print(f"🔒 [VENDOR TUNNEL] {client_ip} → open until {datestop} UTC")

    log_audit("VENDOR_KNOCK", payload.vendor_name, "GRANTED", client_ip,
              {"company": session["company_name"], "clearance": session["clearance_level"],
               "latitude": payload.latitude, "longitude": payload.longitude})

    return {"status": "success", "message": "Vendor tunnel authorised.", "role": "vendor",
            "vendor_name": payload.vendor_name, "company": session["company_name"],
            "valid_until": str(valid_until), "bound_ip": client_ip}


@app.get("/health")
async def health_check():
    return {"status": "ok", "service": "AeroGuard ZTNA Gateway"}


if __name__ == "__main__":
    print("\n" + "=" * 70)
    print("AeroGuard ZTNA Gateway  —  port 8000")
    print("=" * 70)
    print(f"Database : {'SET' if DATABASE_URL else 'MISSING — check .env'}")
    print(f"Port     : {PORT}")
    print("=" * 70 + "\n")
    uvicorn.run("main:app", host="0.0.0.0", port=PORT, reload=False)
