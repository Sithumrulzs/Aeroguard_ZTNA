"""
FIDS single sign-on token — lets a device that the gateway has already
verified (port-knock passed, firewall rule injected) bootstrap a session
on the separate FIDS host without typing a second, independent password.

The token is short-lived and HMAC-signed with a secret shared only
between this gateway and the FIDS app (FIDS_SSO_SECRET in both .env
files) — FIDS trusts it precisely because only the gateway could have
produced a valid signature, never because of who's asking.
"""
import base64
import hashlib
import hmac
import json
import os
import time

TOKEN_TTL_SECONDS = 120  # long enough for the terminal to redeem it once


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def mint_fids_sso_token(username: str, client_ip: str) -> str | None:
    """
    Called only after the gateway itself has confirmed a live, granted
    session for this IP (see main.py's /api/v1/terminal-session) — never
    exposed as a standalone "give me a token" endpoint.
    """
    # Read at call time, not at import time — this module can be imported
    # before main.py's load_dotenv() has actually populated the environment,
    # and re-reading here means the ordering of those two lines never matters.
    secret = os.environ.get("FIDS_SSO_SECRET", "")
    if not secret:
        print("[-] FIDS_SSO_SECRET not set — cannot mint SSO token. "
              "Add it to backend_kali_gateway/.env (see cmb-ops-console setup).")
        return None

    now = int(time.time())
    payload = {
        "u":   username,
        "ip":  client_ip,
        "iat": now,
        "exp": now + TOKEN_TTL_SECONDS,
    }
    payload_b64 = _b64url_encode(json.dumps(payload, separators=(",", ":")).encode())
    signature = hmac.new(secret.encode(), payload_b64.encode(), hashlib.sha256).hexdigest()
    return f"{payload_b64}.{signature}"
