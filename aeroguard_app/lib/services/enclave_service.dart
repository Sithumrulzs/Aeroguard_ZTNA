import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:ecdsa/ecdsa.dart';
import 'package:elliptic/elliptic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Top-level so compute() can serialize the entry point across isolates.
// P-256 key generation is pure Dart math — safe to run off the main thread.
List<String> _generateEcdsaKeyPair(void _) {
  final ec = getP256();
  final privateKey = ec.generatePrivateKey();
  return [privateKey.toHex(), privateKey.publicKey.toHex()];
}

// ECDSA signing is also pure Dart math — runs in background isolate.
String _signPayloadIsolate(Map<String, dynamic> args) {
  final hexKey = args['hexKey'] as String;
  final payload = args['payload'] as String;
  final ec = getP256();
  final privateKey = PrivateKey.fromHex(ec, hexKey);
  final hash = sha256.convert(utf8.encode(payload));
  final sig = signature(privateKey, hash.bytes);
  return sig.toCompactHex();
}

class EnclaveService {
  static const FlutterSecureStorage _vault = FlutterSecureStorage();
  static const String _privateKeyName = 'aeroguard_private_key';
  static const String _publicKeyName = 'aeroguard_public_key';
  static const String _deviceIdName = 'aeroguard_device_id';

  /// Generates and stores hardware keys on first run.
  /// Key generation is offloaded to a background isolate so the loading
  /// animation stays smooth.
  // Key name must match what AuthService stores after a successful login
  static const String _backendDeviceIdKey = 'aeroguard_device_id_from_backend';

  static Future<void> initializeDevice(String username) async {
    final String? existingKey = await _vault.read(key: _privateKeyName);
    final String? backendId   = await _vault.read(key: _backendDeviceIdKey);
    final bool    hasBackendId = backendId != null && backendId.isNotEmpty;

    if (existingKey == null) {
      // First run — generate key pair and store server-assigned device_id.
      debugPrint('[*] No key found. Generating hardware identity...');
      final keys = await compute(_generateEcdsaKeyPair, null);

      final deviceId = hasBackendId
          ? backendId
          : 'admin_${username.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}';

      await _vault.write(key: _privateKeyName, value: keys[0]);
      await _vault.write(key: _publicKeyName,  value: keys[1]);
      await _vault.write(key: _deviceIdName,   value: deviceId);

      debugPrint('[+] Device Provisioned. Private Key locked in vault.');
      debugPrint('[!] PUBLIC KEY FOR DATABASE: ${keys[1]}');
      debugPrint('[!] DEVICE ID: $deviceId');
    } else {
      // Keys already exist — but always sync device_id with the server's
      // latest value so a stale vault ID (e.g. admin_admin) gets corrected.
      if (hasBackendId) {
        final storedId = await _vault.read(key: _deviceIdName);
        if (storedId != backendId) {
          await _vault.write(key: _deviceIdName, value: backendId);
          debugPrint('[~] Device ID synced from server: $backendId');
        }
      }
      debugPrint('[+] Secure Enclave verified. Hardware identity intact.');
    }
  }

  /// Signs a payload using the stored private key.
  /// Signing math runs in a background isolate.
  static Future<String?> signPayload(String payload) async {
    final String? hexKey = await _vault.read(key: _privateKeyName);
    if (hexKey == null) return null;

    return compute(_signPayloadIsolate, {'hexKey': hexKey, 'payload': payload});
  }

  static Future<String> getDeviceId() async {
    final String? id = await _vault.read(key: _deviceIdName);
    return id ?? 'unknown_device';
  }

  static Future<String?> getPublicKey() async {
    final String? storedKey = await _vault.read(key: _publicKeyName);
    if (storedKey != null) return storedKey;

    final String? privateKeyHex = await _vault.read(key: _privateKeyName);
    if (privateKeyHex == null) return null;

    final ec = getP256();
    final privateKey = PrivateKey.fromHex(ec, privateKeyHex);
    final derivedKey = privateKey.publicKey.toHex();
    await _vault.write(key: _publicKeyName, value: derivedKey);
    return derivedKey;
  }

  /// Wipes all local device keys and identity from the vault.
  /// Called when the backend rejects registration (device already bound).
  static Future<void> clearDevice() async {
    await _vault.delete(key: _privateKeyName);
    await _vault.delete(key: _publicKeyName);
    await _vault.delete(key: _deviceIdName);
    debugPrint('[!] Device identity wiped from vault.');
  }

  static Future<Map<String, dynamic>?> generateZeroTrustPayload(
    String username,
  ) async {
    // Always prefer the device_id the server assigned at login.
    // This corrects any stale value (e.g. 'admin_admin') left in the vault
    // from before the central auth server was connected.
    final backendId = await _vault.read(key: _backendDeviceIdKey);
    final localId   = await _vault.read(key: _deviceIdName);
    final deviceId  = (backendId != null && backendId.isNotEmpty)
        ? backendId
        : localId;

    if (deviceId == null) return null;

    final timestamp    = DateTime.now().toUtc().toIso8601String();
    final rawData      = '$deviceId:$username:$timestamp';
    final signatureHex = await signPayload(rawData);
    if (signatureHex == null) return null;

    debugPrint('[*] Knock payload — device_id: $deviceId');

    return {
      'device_id': deviceId,
      'username':  username,
      'timestamp': timestamp,
      'signature': signatureHex,
    };
  }
}
