# config.py

# --- NETWORK SETTINGS ---
LISTEN_IP = "0.0.0.0"       # Listen on all interfaces
KNOCK_PORT = 443          # The port for the Secret Knock
DOOR_OPEN_TIME = 30         # Seconds the firewall stays open

# --- SECURITY SECRETS ---
# MUST be exactly 32 bytes. Match this with your Flutter App!
SECRET_KEY = b"12345678901234567890123456789012"

# --- AUTHORIZED ADMINS (The White List) ---
# Replace 'hw_id' with the real IDs you see in your logs later.
AUTHORIZED_ADMINS = {
    "admin_sithum": {
        "pass": "password123",
        "hw_id": "REPLACE_WITH_REAL_ANDROID_ID", 
        "role": "Chief Network Architect"
    },
    "admin_beta": {
        "pass": "secure456",
        "hw_id": "android_id_987654321",
        "role": "Security Operations"
    },
    "admin_gamma": {
        "pass": "access789",
        "hw_id": "android_id_1122334455",
        "role": "Incident Responder"
    },
    "admin_delta": {
        "pass": "audit000",
        "hw_id": "android_id_9988776655",
        "role": "Penetration Tester"
    }
}
