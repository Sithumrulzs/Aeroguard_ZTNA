"""
AeroGuard ZTNA — Central Auth Server
Handles identity management, login, vendor provisioning, and dashboard APIs.
Connects directly to the Supabase PostgreSQL database via psycopg2.
Credentials are loaded from .env — never hardcoded.
"""

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Optional
from dotenv import load_dotenv
import psycopg2
import psycopg2.extras
import bcrypt
import os
import uvicorn

# ── Load environment ──────────────────────────────────────────────────────────
load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
PORT         = int(os.getenv("PORT", "5432"))
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL not set. Check backend_central_auth/.env")

app = FastAPI(
    title="AeroGuard ZTNA — Central Auth",
    description="Identity, login, vendor provisioning and SIEM dashboard.",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Database connection ───────────────────────────────────────────────────────
@contextmanager
def get_db():
    """Context manager yielding a psycopg2 connection with RealDictCursor."""
    conn = psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def insert_audit(event_type: str, username: str, client_ip: str,
                 status_val: str, details: str):
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                # Let PostgreSQL handle the created_at column natively using its own rules.
                # This prevents ISO format mismatches from breaking the transaction silently.
                cur.execute(
                    """INSERT INTO audit_logs
                       (event_type, username, client_ip, status, details)
                       VALUES (%s, %s, %s, %s, %s)""",
                    (event_type, username, client_ip, status_val, details)
                )
    except Exception as e:
        # This will now explicitly stream the exact error into Choreo logs if your table structure rejects it.
        print(f"\n[CRITICAL AUDIT ERROR] -> Failed to write to public.audit_logs table: {e}\n")


# ── Pydantic models ───────────────────────────────────────────────────────────
class LoginRequest(BaseModel):
    username: str
    password: str

class LogIngestPayload(BaseModel):
    event_type: str
    username:   str
    client_ip:  str
    status:     str
    details:    str

class VendorProvisionPayload(BaseModel):
    vendor_username:  str
    company_name:     str
    clearance_level:  str
    target_device_id: str
    valid_until:      str
    qr_token:         Optional[str] = None


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.get("/")
async def root():
    return {"status": "online", "service": "AeroGuard ZTNA Central Auth"}


@app.post("/api/v1/auth/login")
async def central_login(payload: LoginRequest, request: Request):
    client_ip = request.client.host

    # Sanitize the inputs completely dynamically to clear out trailing whitespaces 
    # that cause string searches to fail on text engines.
    username_clean = payload.username.strip()
    password_clean = payload.password.strip()

    print(f"\n[AEROGUARD LIVE TRACE] Querying DB dynamically for user: '{username_clean}'")

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM users WHERE username = %s", (username_clean,))
                user = cur.fetchone()
        print(f"[AEROGUARD LIVE TRACE] Step 1 Complete -> Database query executed. Row found: {user is not None}")
    except Exception as e:
        print(f"[AEROGUARD LIVE TRACE] Step 1 FAILED -> DB Query broken: {e}")
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    # Verify bcrypt password against fetched database row credentials dynamically
    password_valid = False
    if user:
        print(f"[AEROGUARD LIVE TRACE] Step 2 Complete -> Hash found in table. Running raw bcrypt calculation...")
        try:
            password_valid = bcrypt.checkpw(
                password_clean.encode(),
                user["password_hash"].encode()
            )
            print(f"[AEROGUARD LIVE TRACE] Step 3 Complete -> Cryptographic match result: {password_valid}")
        except Exception as crypto_err:
            print(f"[AEROGUARD LIVE TRACE] Step 3 FAILED -> Bcrypt execution crashed: {crypto_err}")
            password_valid = False

    if not user or not password_valid:
        insert_audit("APP_LOGIN", username_clean, client_ip, "DENIED", "Invalid credentials.")
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Access Denied: Invalid credentials.")

    insert_audit("APP_LOGIN", username_clean, client_ip, "SUCCESS", f"Login successful. Role: {user['role']}")
    print(f"[AEROGUARD LIVE TRACE] SUCCESS -> Access Granted dynamically to administrator workspace: '{username_clean}'\n")

    return {
        "status":    "authenticated",
        "username":  user["username"],
        "role":      user["role"],
        "device_id": user.get("device_id") or "pending",
        "token":     "aeroguard_session_stub",
    }


@app.post("/api/v1/logs/write")
async def ingest_log(payload: LogIngestPayload):
    insert_audit(payload.event_type, payload.username, payload.client_ip,
                 payload.status, payload.details)
    return {"status": "synchronized",
            "message": "Log stored in central SIEM archive."}


@app.post("/api/v1/provision-vendor")
async def provision_vendor(payload: VendorProvisionPayload):
    token = (payload.qr_token or
             f"AEROGUARD_QR_{payload.vendor_username.upper()}_{int(datetime.now().timestamp())}")

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                # Upsert vendor identity into users
                cur.execute(
                    """INSERT INTO users (username, password_hash, role, device_id,
                                         public_key_pem, locked_mac)
                       VALUES (%s, %s, 'vendor', %s, %s, '')
                       ON CONFLICT (username) DO UPDATE
                           SET device_id      = EXCLUDED.device_id,
                               public_key_pem = EXCLUDED.public_key_pem,
                               locked_mac     = ''""",
                    (payload.vendor_username,
                     "ephemeral_vendor_no_pass",
                     payload.target_device_id,
                     "dummy_key_until_scanned")
                )

                # Insert vendor session
                cur.execute(
                    """INSERT INTO vendor_sessions
                       (qr_token, vendor_username, company_name,
                        clearance_level, status, valid_until)
                       VALUES (%s, %s, %s, %s, 'pending', %s)""",
                    (token, payload.vendor_username, payload.company_name,
                     payload.clearance_level, payload.valid_until)
                )

        insert_audit("VENDOR_PROVISION", payload.vendor_username, "CONTROL_PLANE",
                     "SUCCESS",
                     f"Vendor provisioned for {payload.company_name}. Token: {token}")

        return {"status": "profile_synced",
                "message": "Vendor session created.",
                "generated_qr_string": token}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Provision failed: {e}")


@app.get("/api/v1/dashboard/stats")
async def dashboard_stats():
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                # Active admins
                cur.execute("SELECT username FROM users WHERE role = 'admin'")
                admins      = cur.fetchall()
                admin_names = [r["username"] for r in admins]

                # Active vendors (unexpired sessions)
                now = datetime.now(timezone.utc).isoformat()
                cur.execute(
                    "SELECT DISTINCT vendor_username FROM vendor_sessions "
                    "WHERE valid_until > %s AND status != 'expired'", (now,)
                )
                active_vendors = cur.fetchall()

                # Successful ZTNA knocks today
                today = datetime.now(timezone.utc).date().isoformat()
                cur.execute(
                    "SELECT COUNT(*) AS cnt FROM audit_logs "
                    "WHERE event_type = 'ZTNA_KNOCK' AND status = 'GRANTED' "
                    "AND created_at >= %s", (today,)
                )
                knocks = cur.fetchone()["cnt"]

        return {
            "active_admins":      len(admin_names),
            "admin_names":        admin_names,
            "active_vendors":     len(active_vendors),
            "total_knocks_today": knocks,
            "gateway_status":     "SECURED",
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Stats query failed: {e}")


@app.get("/api/v1/dashboard/telemetry")
async def dashboard_telemetry(limit: int = 10):
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                # Recent audit events
                cur.execute(
                    "SELECT event_type, username, client_ip, status, details, created_at "
                    "FROM audit_logs ORDER BY created_at DESC LIMIT %s", (limit,)
                )
                events = cur.fetchall()

                # Active admins
                cur.execute("SELECT username FROM users WHERE role = 'admin'")
                admin_names = [r["username"] for r in cur.fetchall()]

                # Active vendors
                now = datetime.now(timezone.utc).isoformat()
                cur.execute(
                    "SELECT DISTINCT vendor_username FROM vendor_sessions "
                    "WHERE valid_until > %s AND status != 'expired'", (now,)
                )
                vendor_names = [r["vendor_username"] for r in cur.fetchall()]

        return {
            "events":              [dict(e) for e in events],
            "active_admins":       len(admin_names),
            "active_admin_names":  admin_names,
            "active_vendors":      len(vendor_names),
            "active_vendor_names": vendor_names,
            "gateway_status":      "SECURED",
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Telemetry query failed: {e}")


@app.get("/health")
async def health_check():
    return {"status": "ok", "service": "AeroGuard Central Auth"}


if __name__ == "__main__":
    print("\n" + "=" * 70)
    print("AeroGuard Central Auth  —  port 8001")
    print("=" * 70)
    print(f"Database : {'SET' if DATABASE_URL else 'MISSING — check .env'}")
    print(f"Port     : {PORT}")
    print("=" * 70 + "\n")
    uvicorn.run("main:app", host="0.0.0.0", port=PORT, reload=False)
