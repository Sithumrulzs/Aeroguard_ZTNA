# core/crypto.py
import json
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import padding
from config import SECRET_KEY

def decrypt_payload(raw_bytes):
    try:
        # 1. Extract IV (First 16 bytes) and Ciphertext
        if len(raw_bytes) < 16:
            return None
            
        iv = raw_bytes[:16]
        ciphertext = raw_bytes[16:]

        # 2. Setup Decryption (AES-CBC)
        cipher = Cipher(algorithms.AES(SECRET_KEY), modes.CBC(iv), backend=default_backend())
        decryptor = cipher.decryptor()
        
        # 3. Decrypt
        decrypted_padded = decryptor.update(ciphertext) + decryptor.finalize()
        
        # 4. Unpad (PKCS7)
        # Flutter's 'encrypt' package adds padding. We must remove it.
        unpadder = padding.PKCS7(128).unpadder()
        decrypted_data = unpadder.update(decrypted_padded) + unpadder.finalize()
        
        # 5. Convert to JSON
        return json.loads(decrypted_data.decode('utf-8'))
        
    except Exception as e:
        # Don't crash on bad crypto, just return None (Invalid)
        return None