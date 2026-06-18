"""
AeroGuard ZTNA — Central Auth Server
Handles identity management, login, vendor provisioning, and dashboard APIs.
Connects directly to the Supabase PostgreSQL database via psycopg2.
Credentials are loaded from .env — never hardcoded.
"""

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timezone
from typing import Optional
from dotenv import load_dotenv
import psycopg2
import psycopg2.extras
import bcrypt
import json
import os
import urllib.request
import urllib.parse
import uvicorn

# ── Load environment ──────────────────────────────────────────────────────────
load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
PORT         = int(os.getenv("PORT", "8001"))
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL not set. Check backend_central_auth/.env")

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
                cur.execute(
                    """INSERT INTO public.audit_logs
                       (event_type, username, client_ip, status, details)
                       VALUES (%s, %s, %s, %s, %s)""",
                    (event_type, username, client_ip, status_val, details)
                )
    except Exception as e:
        print(f"\n[CRITICAL AUDIT ERROR] -> Failed to write to public.audit_logs table: {e}\n")


# ── System Startup Verification ───────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    print("\n" + "="*80)
    print("[AEROGUARD SYSTEM] Starting Central Auth Control Plane...")
    print("="*80)
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1;")
                cur.fetchone()
        print("[DATABASE STATUS] CONNECTED")
        print("[DATABASE STATUS] Secure link to Supabase PostgreSQL is fully functional.")
        print("[SYSTEM STATUS]   AeroGuard ZTNA engine is ready to accept inbound traffic.")
    except Exception as e:
        print("[DATABASE STATUS] ERROR")
        print(f"[CRITICAL FAILURE] Reason: {e}")
        print("[SYSTEM STATUS]   Server starting in a degraded or disconnected state.")
    print("="*80 + "\n")
    yield


app = FastAPI(
    title="AeroGuard ZTNA — Central Auth",
    description="Identity, login, vendor provisioning and SIEM dashboard.",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

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

class RegisterDevicePayload(BaseModel):
    username:       str
    device_id:      str
    public_key_pem: str

class AdminResetPayload(BaseModel):
    superadmin_username: str
    target_username:     str

class RevokeVendorPayload(BaseModel):
    admin_username:  str
    vendor_username: str

class LocationUpdatePayload(BaseModel):
    username:  str
    latitude:  float
    longitude: float

class VendorLocationPayload(BaseModel):
    token_hash: str
    latitude:   float
    longitude:  float

class ApproveVendorDevicePayload(BaseModel):
    token_hash:     str
    admin_username: str
    approved:       bool
    override_ip:    Optional[str] = None
    override_mac:   Optional[str] = None


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
                cur.execute("SELECT * FROM public.users WHERE username = %s", (username_clean,))
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
            stored_hash = user["password_hash"]
            stored_hash_bytes = stored_hash.encode('utf-8') if isinstance(stored_hash, str) else stored_hash

            password_valid = bcrypt.checkpw(
                password_clean.encode('utf-8'),
                stored_hash_bytes
            )
            print(f"[AEROGUARD LIVE TRACE] Step 3 Complete -> Cryptographic match result: {password_valid}")
        except Exception as crypto_err:
            print(f"[AEROGUARD LIVE TRACE] Step 3 FAILED -> Bcrypt execution crashed: {crypto_err}")
            password_valid = False

    if not user or not password_valid:
        insert_audit("APP_LOGIN", username_clean, client_ip, "DENIED", "Invalid credentials.")
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="Access Denied: Invalid credentials.")

    # Track last login time so the dashboard can show "active" admins
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE public.users SET last_login_at = NOW() WHERE username = %s",
                    (username_clean,)
                )
    except Exception as e:
        print(f"[!] last_login_at update skipped: {e}")

    insert_audit("APP_LOGIN", username_clean, client_ip, "SUCCESS", f"Login successful. Role: {user['role']}")
    print(f"[AEROGUARD LIVE TRACE] SUCCESS -> Access Granted dynamically to administrator workspace: '{username_clean}'\n")

    # Use the stored device_id, but never let the sentinel "pending" leak out.
    # Fall back to the username so admins are identified as e.g. "sithum.it"
    # and vendors by their assigned login name.
    stored_device_id = user.get("device_id")
    effective_device_id = (
        stored_device_id
        if (stored_device_id and stored_device_id != "pending")
        else user["username"]
    )

    return {
        "status":    "authenticated",
        "username":  user["username"],
        "role":      user["role"],
        "device_id": effective_device_id,
        "token":     "aeroguard_session_stub",
    }


@app.post("/api/v1/auth/register-device")
async def register_device(payload: RegisterDevicePayload, request: Request):
    client_ip = request.client.host
    username  = payload.username.strip()

    # Placeholder values written by seed/admin scripts — treated as unbound.
    # "pending" is included so any corrupted rows are transparently re-bound.
    DUMMY_KEYS = {
        "dummy_key_until_flutter_is_connected",
        "dummy_key_until_scanned",
        "manual_admin_provision",
        "pending",
        "",
    }

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT public_key_pem, device_id FROM public.users WHERE username = %s",
                    (username,)
                )
                row = cur.fetchone()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    if not row:
        raise HTTPException(status_code=404, detail="User not found.")

    existing_key    = row["public_key_pem"] or ""
    existing_device = row["device_id"]      or ""

    # ── TOFU decision tree ────────────────────────────────────────────────────
    if not existing_key or existing_key in DUMMY_KEYS:
        # Slot is empty/placeholder → bind freely.
        pass

    elif existing_key == payload.public_key_pem:
        # Exact same key → same device re-logging in.
        # If device_id is a placeholder (e.g. "pending"), refresh it now.
        STALE_DEVICE_IDS = {"pending", "", None}
        if existing_device in STALE_DEVICE_IDS or existing_device != payload.device_id:
            try:
                with get_db() as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            "UPDATE public.users SET device_id = %s WHERE username = %s",
                            (payload.device_id, username)
                        )
            except Exception:
                pass  # non-fatal
        insert_audit("DEVICE_BIND", username, client_ip, "SKIP",
                     f"Device already registered. ID: {payload.device_id}")
        return {"status": "already_registered", "message": "Device already registered."}

    elif existing_device and existing_device == payload.device_id:
        # Same device_id but key refreshed (e.g. app reinstall) → allow re-bind.
        pass

    else:
        # Genuinely different device — TOFU violation.
        insert_audit("DEVICE_BIND", username, client_ip, "DENIED",
                     f"Account already bound to a different device. Stored: {existing_device}")
        raise HTTPException(status_code=403,
                            detail="Account already bound to a device.")
    # ─────────────────────────────────────────────────────────────────────────

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """UPDATE public.users
                       SET public_key_pem = %s, device_id = %s
                       WHERE username = %s""",
                    (payload.public_key_pem, payload.device_id, username)
                )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    insert_audit("DEVICE_BIND", username, client_ip, "SUCCESS",
                 f"Device bound. ID: {payload.device_id}")
    print(f"[+] DEVICE BOUND: {username} -> {payload.device_id}")
    return {"status": "bound", "message": "Device successfully registered."}


@app.post("/api/v1/auth/admin/reset-device")
async def admin_reset_device(payload: AdminResetPayload, request: Request):
    client_ip   = request.client.host
    superadmin  = payload.superadmin_username.strip()
    target      = payload.target_username.strip()

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT role FROM public.users WHERE username = %s",
                    (superadmin,)
                )
                row = cur.fetchone()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    if not row or row["role"] != "superadmin":
        insert_audit("DEVICE_RESET", superadmin, client_ip, "DENIED",
                     "Unauthorized reset attempt.")
        raise HTTPException(status_code=403,
                            detail="Access Denied: Superadmin privileges required.")

    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """UPDATE public.users
                       SET public_key_pem = NULL, device_id = NULL
                       WHERE username = %s""",
                    (target,)
                )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    insert_audit("DEVICE_RESET", superadmin, client_ip, "SUCCESS",
                 f"Device binding reset for {target}.")
    print(f"[+] DEVICE RESET: {target} (by {superadmin})")
    return {"status": "reset", "message": f"Device binding cleared for {target}."}


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
                # Upsert vendor identity into public.users
                cur.execute(
                    """INSERT INTO public.users (username, password_hash, role, device_id,
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

                # Insert vendor session into public.vendor_sessions
                cur.execute(
                    """INSERT INTO public.vendor_sessions
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
        # ── Active admins: logged in within last 24 h ─────────────────────────
        # Falls back to all admin accounts if last_login_at column not yet added.
        try:
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT username FROM public.users "
                        "WHERE role IN ('admin', 'superadmin') "
                        "AND last_login_at IS NOT NULL "
                        "AND last_login_at > NOW() - INTERVAL '24 hours' "
                        "ORDER BY last_login_at DESC"
                    )
                    rows = cur.fetchall()
                    if not rows:
                        # No recent logins yet — return all registered admins
                        cur.execute(
                            "SELECT username FROM public.users "
                            "WHERE role IN ('admin', 'superadmin')"
                        )
                        rows = cur.fetchall()
                    admin_names = [r["username"] for r in rows]
        except Exception:
            with get_db() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT username FROM public.users "
                        "WHERE role IN ('admin', 'superadmin')"
                    )
                    admin_names = [r["username"] for r in cur.fetchall()]

        # ── Active vendors ────────────────────────────────────────────────────
        now = datetime.now(timezone.utc).isoformat()
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT DISTINCT vendor_username FROM public.vendor_sessions "
                    "WHERE valid_until > %s AND status != 'expired'", (now,)
                )
                vendor_names = [r["vendor_username"] for r in cur.fetchall()]

        # ── Knocks today ──────────────────────────────────────────────────────
        today = datetime.now(timezone.utc).date().isoformat()
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COUNT(*) AS cnt FROM public.audit_logs "
                    "WHERE event_type = 'ZTNA_KNOCK' AND status = 'GRANTED' "
                    "AND created_at >= %s", (today,)
                )
                knocks = cur.fetchone()["cnt"]

        return {
            "active_admins":          len(admin_names),
            "admin_names":            admin_names,
            "registered_admins":      len(admin_names),
            "registered_admin_names": admin_names,
            "active_vendors":         len(vendor_names),
            "vendor_names":           vendor_names,
            "total_knocks_today":     knocks,
            "gateway_status":         "SECURED",
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
                    "FROM public.audit_logs ORDER BY created_at DESC LIMIT %s", (limit,)
                )
                events = cur.fetchall()

                # All registered admins
                cur.execute(
                    "SELECT username FROM public.users "
                    "WHERE role IN ('admin', 'superadmin') ORDER BY username"
                )
                admin_names = [r["username"] for r in cur.fetchall()]

                # Active vendors
                now = datetime.now(timezone.utc).isoformat()
                cur.execute(
                    "SELECT DISTINCT vendor_username FROM public.vendor_sessions "
                    "WHERE valid_until > %s AND status != 'expired'", (now,)
                )
                vendor_names = [r["vendor_username"] for r in cur.fetchall()]

                # Last knock (admin or vendor)
                cur.execute(
                    "SELECT created_at FROM public.audit_logs "
                    "WHERE event_type IN ('ZTNA_KNOCK', 'VENDOR_KNOCK') "
                    "ORDER BY created_at DESC LIMIT 1"
                )
                knock_row = cur.fetchone()
                last_knock_at = knock_row["created_at"].isoformat() if knock_row else None

        return {
            "events":                 [dict(e) for e in events],
            "active_admins":          len(admin_names),
            "active_admin_names":     admin_names,
            "registered_admins":      len(admin_names),
            "registered_admin_names": admin_names,
            "active_vendors":         len(vendor_names),
            "active_vendor_names":    vendor_names,
            "gateway_status":         "SECURED",
            "last_knock_at":          last_knock_at,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Telemetry query failed: {e}")


@app.get("/api/v1/dashboard/vendor-sessions")
async def get_vendor_sessions():
    try:
        now = datetime.now(timezone.utc).isoformat()
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """SELECT qr_token, vendor_username, company_name,
                              clearance_level, status, valid_until
                       FROM public.vendor_sessions
                       WHERE valid_until > %s AND status NOT IN ('expired', 'revoked')
                       ORDER BY valid_until ASC""",
                    (now,)
                )
                sessions = [dict(s) for s in cur.fetchall()]

        # Last knock event (admin or vendor) for the vault panel
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT created_at FROM public.audit_logs "
                    "WHERE event_type IN ('ZTNA_KNOCK', 'VENDOR_KNOCK') "
                    "ORDER BY created_at DESC LIMIT 1"
                )
                row = cur.fetchone()
                last_knock_at = row["created_at"].isoformat() if row else None

        # Serialize datetime fields to ISO strings
        for s in sessions:
            if hasattr(s.get("valid_until"), "isoformat"):
                s["valid_until"] = s["valid_until"].isoformat()

        return {"sessions": sessions, "last_knock_at": last_knock_at}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Query failed: {e}")


@app.post("/api/v1/admin/revoke-vendor")
async def revoke_vendor(payload: RevokeVendorPayload, request: Request):
    client_ip = request.client.host
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """UPDATE public.vendor_sessions
                       SET status = 'revoked'
                       WHERE vendor_username = %s
                         AND status NOT IN ('expired', 'revoked')""",
                    (payload.vendor_username,)
                )
                affected = cur.rowcount
        insert_audit(
            "VENDOR_REVOKE", payload.vendor_username, client_ip,
            "SUCCESS" if affected > 0 else "NOT_FOUND",
            f"Session revoked by admin: {payload.admin_username}"
        )
        print(f"[!] VENDOR REVOKED: {payload.vendor_username} by {payload.admin_username}")
        return {"status": "revoked", "sessions_affected": affected}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Revoke failed: {e}")


def _reverse_geocode(lat: float, lng: float) -> str:
    """
    Convert coordinates to a street-level address via OpenStreetMap Nominatim.
    zoom=18 = building level (most precise). Falls back to raw coords on error.
    """
    try:
        params = urllib.parse.urlencode({
            "lat": lat, "lon": lng,
            "format": "json",
            "zoom": 18,
            "addressdetails": 1,
        })
        req = urllib.request.Request(
            f"https://nominatim.openstreetmap.org/reverse?{params}",
            headers={"User-Agent": "AeroGuard-ZTNA/1.0 (security-platform)"},
        )
        with urllib.request.urlopen(req, timeout=6) as resp:
            data = json.loads(resp.read().decode())

        addr = data.get("address", {})
        parts = []

        # Building / house number + road
        road = (addr.get("road") or addr.get("pedestrian")
                or addr.get("footway") or addr.get("path"))
        if road:
            house = addr.get("house_number", "")
            parts.append(f"{house} {road}".strip() if house else road)

        # Neighbourhood / suburb / quarter
        area = (addr.get("neighbourhood") or addr.get("suburb")
                or addr.get("quarter") or addr.get("city_district"))
        if area:
            parts.append(area)

        # City / town / village
        city = (addr.get("city") or addr.get("town")
                or addr.get("village") or addr.get("municipality"))
        if city:
            parts.append(city)

        # Postal code
        if addr.get("postcode"):
            parts.append(addr["postcode"])

        # State + country
        if addr.get("state"):
            parts.append(addr["state"])
        if addr.get("country"):
            parts.append(addr["country"])

        return ", ".join(parts) if parts else data.get("display_name", f"{lat:.6f}, {lng:.6f}")

    except Exception:
        return f"{lat:.6f}° N, {lng:.6f}° E"


@app.post("/api/v1/auth/update-location")
async def update_user_location(payload: LocationUpdatePayload):
    location_name = _reverse_geocode(payload.latitude, payload.longitude)
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """UPDATE public.users
                       SET last_seen_lat      = %s,
                           last_seen_lng      = %s,
                           last_seen_at       = %s,
                           last_seen_location = %s
                       WHERE username = %s""",
                    (payload.latitude, payload.longitude,
                     datetime.now(timezone.utc).isoformat(),
                     location_name, payload.username)
                )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Location update failed: {e}")
    return {"status": "ok", "location": location_name}


@app.post("/api/v1/vendor/update-location")
async def update_vendor_location(payload: VendorLocationPayload):
    """Records GPS coordinates + resolved address against the vendor session."""
    location_name = _reverse_geocode(payload.latitude, payload.longitude)
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """UPDATE public.vendor_sessions
                       SET last_seen_lat      = %s,
                           last_seen_lng      = %s,
                           last_seen_at       = %s,
                           last_seen_location = %s
                       WHERE qr_token = %s""",
                    (payload.latitude, payload.longitude,
                     datetime.now(timezone.utc).isoformat(),
                     location_name, payload.token_hash)
                )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Vendor location update failed: {e}")
    return {"status": "ok", "location": location_name}


@app.get("/api/v1/dashboard/threats")
async def get_threats():
    """Return recent unauthorized knock attempts from the last 2 minutes."""
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """SELECT event_type, username, client_ip, status, created_at
                       FROM public.audit_logs
                       WHERE status LIKE 'DENIED%%'
                         AND created_at > NOW() AT TIME ZONE 'UTC' - INTERVAL '2 minutes'
                       ORDER BY created_at DESC
                       LIMIT 20"""
                )
                rows = cur.fetchall()
        threats = [dict(r) for r in rows]
        last = threats[0] if threats else None
        return {
            "recent_count":   len(threats),
            "last_threat_at": str(last["created_at"]) if last else None,
            "last_threat_type": last["status"]     if last else None,
            "last_threat_ip":   last["client_ip"]  if last else None,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")


@app.get("/api/v1/dashboard/pending-vendor-devices")
async def get_pending_vendor_devices():
    """Return vendor sessions that have a detected device awaiting admin approval."""
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """SELECT qr_token, vendor_username, company_name,
                              pending_device_ip, pending_device_mac,
                              device_approved, valid_until
                       FROM public.vendor_sessions
                       WHERE pending_device_ip IS NOT NULL
                         AND (device_approved IS NULL OR device_approved = FALSE)
                         AND status NOT IN ('expired', 'revoked')
                       ORDER BY created_at DESC"""
                )
                rows = cur.fetchall()
        return {"pending": [dict(r) for r in rows]}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")


@app.post("/api/v1/admin/approve-vendor-device")
async def approve_vendor_device(payload: ApproveVendorDevicePayload, request: Request):
    """Admin approves or denies a vendor's detected device."""
    client_ip = request.client.host
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                if payload.approved:
                    if payload.override_ip:
                        # Admin manually selected a device — override auto-detected IP/MAC
                        cur.execute(
                            """UPDATE public.vendor_sessions
                               SET device_approved    = TRUE,
                                   device_approved_at = %s,
                                   pending_device_ip  = %s,
                                   pending_device_mac = %s
                               WHERE qr_token = %s""",
                            (datetime.now(timezone.utc).isoformat(),
                             payload.override_ip,
                             payload.override_mac or '',
                             payload.token_hash)
                        )
                    else:
                        cur.execute(
                            """UPDATE public.vendor_sessions
                               SET device_approved    = TRUE,
                                   device_approved_at = %s
                               WHERE qr_token = %s""",
                            (datetime.now(timezone.utc).isoformat(), payload.token_hash)
                        )
                else:
                    # Denial: clear pending fields so vendor can try again
                    cur.execute(
                        """UPDATE public.vendor_sessions
                           SET device_approved    = FALSE,
                               pending_device_ip  = NULL,
                               pending_device_mac = NULL
                           WHERE qr_token = %s""",
                        (payload.token_hash,)
                    )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    action = "APPROVED" if payload.approved else "DENIED"
    insert_audit("DEVICE_APPROVAL", payload.admin_username, client_ip, action,
                 f"Device {action.lower()} for token {payload.token_hash[:12]}...")
    print(f"[{'+'  if payload.approved else '!'}] DEVICE {action}  by {payload.admin_username}")
    return {"status": "ok", "approved": payload.approved}


@app.get("/api/v1/vendor/device-status")
async def vendor_device_status(token: str):
    """Vendor app polls this to learn if their device has been approved."""
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """SELECT status, device_approved, pending_device_ip,
                              pending_device_mac, valid_until
                       FROM public.vendor_sessions
                       WHERE qr_token = %s""",
                    (token,)
                )
                row = cur.fetchone()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    if not row:
        raise HTTPException(status_code=404, detail="Session not found.")

    # Check wall-clock expiry so the vendor app navigates back even when the
    # sniffer's session timer fires but the DB status hasn't been updated yet.
    try:
        expiry = datetime.fromisoformat(str(row["valid_until"]).replace("Z", "+00:00"))
        if datetime.now(timezone.utc) > expiry:
            return {
                "status":          "expired",
                "device_approved": bool(row["device_approved"]),
                "device_ip":       row["pending_device_ip"] or "",
                "device_mac":      row["pending_device_mac"] or "",
            }
    except Exception:
        pass

    if row["status"] in ("expired", "revoked"):
        poll_status = row["status"]
    elif row["device_approved"]:
        poll_status = "device_approved"
    elif row["pending_device_ip"]:
        poll_status = "pending_device_approval"
    else:
        poll_status = row["status"]

    return {
        "status":          poll_status,
        "device_approved": bool(row["device_approved"]),
        "device_ip":       row["pending_device_ip"] or "",
        "device_mac":      row["pending_device_mac"] or "",
    }


@app.get("/health")
async def health_check():
    return {"status": "ok", "service": "AeroGuard Central Auth"}


if __name__ == "__main__":
    # 1. Dynamically read Render's port, default to 8001 if testing locally
    RENDER_PORT = int(os.getenv("PORT", 8001))
    
    print("\n" + "=" * 70)
    print("AeroGuard Central Auth  —  Active Engine")
    print("=" * 70)
    print(f"Database : {'SET' if DATABASE_URL else 'MISSING — check .env'}")
    print(f"Port     : {RENDER_PORT}")
    print("=" * 70 + "\n")
    
    # 2. Run Uvicorn using the dynamic port variable
    uvicorn.run("main:app", host="0.0.0.0", port=RENDER_PORT, reload=False)
