import os

# --- NETWORK CONFIGURATION ---
LISTEN_IP = "0.0.0.0"
KNOCK_PORT = 8000
WIFI_INTERFACE = "wlan0"

# --- FIDS (cmb-ops-console) ---
# FIDS lives on its own dedicated VM (Option B: never on the gateway or
# on an operator's laptop). Reachable only over the isolated
# "Aeroguard-internal" link, deliberately NOT on 192.168.100.0/24 — that
# range collides with real-world home/office LAN DHCP pools (confirmed
# live: this gateway's own bridged/vendor-facing NIC got 192.168.100.130
# from a real router), which would make the "isolated" internal segment
# ambiguous with the untrusted LAN on any host that has both. Never
# 127.0.0.1 in a real deployment — that would put FIDS back on whichever
# machine reads this config.
FIDS_HOST = os.environ.get("FIDS_HOST", "10.66.100.150")
FIDS_PORT = int(os.environ.get("FIDS_PORT", "3000"))

# --- FILE PATHS ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE_PATH = os.path.join(BASE_DIR, "logs", "access.log")