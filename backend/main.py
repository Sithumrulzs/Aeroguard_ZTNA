import json
import time
from scapy.all import sniff, UDP, IP, send
from config import LISTEN_IP, KNOCK_PORT, SECRET_KEY

# A simple in-memory list to store recent alerts
ALERT_QUEUE = []

def log_threat(ip, reason):
    alert = {
        "timestamp": time.strftime("%H:%M:%S"),
        "src_ip": ip,
        "message": reason,
        "severity": "HIGH"
    }
    ALERT_QUEUE.append(alert)
    # Keep only last 10 alerts to save memory
    if len(ALERT_QUEUE) > 10:
        ALERT_QUEUE.pop(0)
    print(f"[ALERT LOGGED] {reason} from {ip}")

def packet_callback(packet):
    if packet.haslayer(UDP) and packet[UDP].dport == KNOCK_PORT:
        sender_ip = packet[IP].src
        raw_data = bytes(packet[UDP].payload)

        try:
            # Check if this is a "POLL" request (The App asking for updates)
            if raw_data == b"GET_ALERTS":
                # Send the ALERT_QUEUE back to the phone
                response = json.dumps({"alerts": ALERT_QUEUE}).encode('utf-8')
                # Send back to the phone's IP on the same port
                send(IP(dst=sender_ip)/UDP(dport=KNOCK_PORT)/response, verbose=0)
                return

            # If not a poll, try to Decrypt (Normal Logic)
            # ... (Your existing decryption logic here) ...
            
            # IF DECRYPTION FAILS or INVALID USER:
            # log_threat(sender_ip, "Invalid Encryption Key")
            
        except Exception as e:
            log_threat(sender_ip, f"Malformed Packet: {str(e)}")

# Start Sniffing
print(f"[*] AERO-GUARD DASHBOARD SERVER RUNNING...")
sniff(filter=f"udp port {KNOCK_PORT}", prn=packet_callback, store=0)