import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';

/// Manages authentication with the AeroGuard backend
class AuthService {
  static const String _usernameKey = 'aeroguard_username';
  static const String _deviceIdKey = 'aeroguard_device_id_from_backend';
  static const String _bioUsernameKey = 'aeroguard_bio_username';
  static const String _bioPasswordKey = 'aeroguard_bio_password';
  static const String _vendorTokenKey   = 'aeroguard_vendor_token';
  static const String _vendorNameKey    = 'aeroguard_vendor_name';
  static const String _vendorCompanyKey = 'aeroguard_vendor_company';
  static const String _vendorExpiresKey = 'aeroguard_vendor_expires';

  static final _vault = const FlutterSecureStorage();

  /// Authenticate against the central auth server hosted on Choreo.
  static Future<AuthResponse> login(String username, String password) async {
    try {
      // Login goes to central auth server (port 8000), not the gateway
      final uri = Uri.parse(ApiConstants.loginEndpoint);

      debugPrint('[*] Attempting login for user: $username');
      debugPrint('[*] Central Auth: ${uri.toString()}');

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(
            const Duration(seconds: 6),
            onTimeout: () => throw Exception('timeout'),
          );

      debugPrint('[*] Login response status: ${response.statusCode}');

      debugPrint('[*] Login response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Central auth returns: {status, username, role, device_id, token}
        await _vault.write(
          key: _usernameKey,
          value: data['username'] ?? username,
        );
        await _vault.write(key: _deviceIdKey, value: data['device_id'] ?? '');

        debugPrint('[+] LOGIN SUCCESSFUL: ${data['username']}');

        return AuthResponse(
          success: true,
          username: data['username'] ?? username,
          deviceId: data['device_id'] ?? '',
          message: 'Authentication successful',
        );
      } else if (response.statusCode == 401) {
        return AuthResponse(
          success: false,
          message: 'Invalid username or password',
        );
      } else {
        return AuthResponse(
          success: false,
          message: 'Login failed: ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[-] Central auth unreachable: $e');
      return AuthResponse(
        success: false,
        message:
            'Authentication server unreachable. Check your network and CENTRAL_AUTH_URL setting.',
      );
    }
  }

  // ── Device binding (PKI / TOFU) ──────────────────────────────────────────

  /// Registers the device's public key with the backend.
  /// Returns the HTTP status code: 200 = bound, 403 = already bound, 5xx = error.
  static Future<int> registerDevice(
      String username, String deviceId, String publicKey) async {
    try {
      final uri = Uri.parse(ApiConstants.registerDeviceEndpoint);
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username':       username,
              'device_id':      deviceId,
              'public_key_pem': publicKey,
            }),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('[*] Device registration status: ${response.statusCode}');
      return response.statusCode;
    } catch (e) {
      debugPrint('[-] Device registration request failed: $e');
      return 500;
    }
  }

  // ── Biometric credential storage ──────────────────────────────────────────

  /// Save credentials so the biometric screen can log in automatically.
  static Future<void> saveBiometricCredentials(
    String username,
    String password,
  ) async {
    await _vault.write(key: _bioUsernameKey, value: username);
    await _vault.write(key: _bioPasswordKey, value: password);
    debugPrint('[+] Biometric credentials saved for: $username');
  }

  /// Returns stored credentials or null if none saved.
  static Future<Map<String, String>?> getBiometricCredentials() async {
    final username = await _vault.read(key: _bioUsernameKey);
    final password = await _vault.read(key: _bioPasswordKey);
    if (username != null && password != null) {
      return {'username': username, 'password': password};
    }
    return null;
  }

  /// True if biometric credentials have been saved on this device.
  static Future<bool> hasBiometricCredentials() async {
    final creds = await getBiometricCredentials();
    return creds != null;
  }

  /// Remove saved biometric credentials (call on logout or manual revoke).
  static Future<void> clearBiometricCredentials() async {
    await _vault.delete(key: _bioUsernameKey);
    await _vault.delete(key: _bioPasswordKey);
    debugPrint('[+] Biometric credentials cleared');
  }

  // ── Session ──────────────────────────────────────────────────────────────

  /// Get currently authenticated username
  static Future<String?> getUsername() async {
    return await _vault.read(key: _usernameKey);
  }

  /// Get device_id from backend
  static Future<String?> getBackendDeviceId() async {
    return await _vault.read(key: _deviceIdKey);
  }

  /// Check if user is authenticated
  static Future<bool> isAuthenticated() async {
    final username = await getUsername();
    return username != null && username.isNotEmpty;
  }

  /// Logout — clears session and biometric credentials.
  static Future<void> logout() async {
    await _vault.delete(key: _usernameKey);
    await _vault.delete(key: _deviceIdKey);
    await clearBiometricCredentials();
    debugPrint('[+] User logged out');
  }

  // ── Vendor session persistence ──────────────────────────────────────────
  // The vendor's identity lives entirely in the QR-derived token — closing
  // the app loses all of it unless saved here, even though the session on
  // the backend is still perfectly alive. Saved the moment a QR is scanned,
  // cleared once the session is expired/revoked or the vendor signs out.

  /// Persist the session right after a successful QR scan (or any later
  /// state change worth remembering across an app restart).
  static Future<void> saveVendorSession({
    required String token,
    required String vendorName,
    required String company,
    required String expiresAt,
  }) async {
    await _vault.write(key: _vendorTokenKey,   value: token);
    await _vault.write(key: _vendorNameKey,    value: vendorName);
    await _vault.write(key: _vendorCompanyKey, value: company);
    await _vault.write(key: _vendorExpiresKey, value: expiresAt);
  }

  /// Returns the saved vendor session, or null if none exists.
  static Future<Map<String, String>?> getVendorSession() async {
    final token = await _vault.read(key: _vendorTokenKey);
    if (token == null || token.isEmpty) return null;
    return {
      'token':      token,
      'vendorName': await _vault.read(key: _vendorNameKey)    ?? '',
      'company':    await _vault.read(key: _vendorCompanyKey) ?? '',
      'expiresAt':  await _vault.read(key: _vendorExpiresKey) ?? '',
    };
  }

  /// Clear the saved vendor session — call on expiry, revoke, or sign-out.
  static Future<void> clearVendorSession() async {
    await _vault.delete(key: _vendorTokenKey);
    await _vault.delete(key: _vendorNameKey);
    await _vault.delete(key: _vendorCompanyKey);
    await _vault.delete(key: _vendorExpiresKey);
  }
}

/// Response model for login
class AuthResponse {
  final bool success;
  final String? username;
  final String? deviceId;
  final String message;

  AuthResponse({
    required this.success,
    this.username,
    this.deviceId,
    required this.message,
  });
}
