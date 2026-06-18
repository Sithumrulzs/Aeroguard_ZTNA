import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';
import 'enclave_service.dart';
import 'location_service.dart';


class NetworkService {
  static final Uri _knockUri = Uri.parse(ApiConstants.knockEndpoint);

  static Future<bool> sendAuthorizationKnock(String username) async {
    final Map<String, dynamic>? payload =
        await EnclaveService.generateZeroTrustPayload(username);

    if (payload == null) {
      debugPrint('[-] Enclave payload null — device not provisioned.');
      return false;
    }

    final body      = <String, dynamic>{...payload, 'telemetry': const <String, dynamic>{}};
    final bodyBytes = utf8.encode(jsonEncode(body));

    // ── 1. UDP knock → port 7777 ─────────────────────────────────────────────
    // Scapy sniffer sees this via raw socket even though iptables DROPs it
    // for the normal UDP stack. No response is expected.
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.send(bodyBytes,
                InternetAddress(ApiConstants.gatewayIp),
                ApiConstants.udpKnockPort);
      sock.close();
      debugPrint('[*] UDP knock → ${ApiConstants.gatewayIp}:${ApiConstants.udpKnockPort}');
    } catch (e) {
      debugPrint('[-] UDP send failed: $e');
      return false;
    }

    // ── 2. Wait for sniffer to inject iptables ACCEPT + DNAT rule ───────────
    await Future.delayed(const Duration(seconds: 2));

    // ── 3. HTTP POST — port 8000 is now open for this IP via DNAT ───────────
    try {
      final response = await http
          .post(
            _knockUri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(Duration(seconds: ApiConstants.connectionTimeoutSeconds));

      if (response.statusCode == 200) {
        debugPrint('[+] KNOCK ACCEPTED — gateway open.');
        LocationService.sendToBackend(username);
        return true;
      }
      debugPrint('[-] KNOCK DENIED — HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[-] Gateway unreachable: $e');
      return false;
    }
  }

  /// Terminates the admin's active session — removes iptables rules for
  /// phone + laptop on the gateway. Best-effort: if gateway is already
  /// offline this silently succeeds so the UI still resets.
  static Future<void> revokeAdminSession(String username) async {
    try {
      await http
          .post(
            Uri.parse(ApiConstants.revokeAdminSessionEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username}),
          )
          .timeout(const Duration(seconds: 5));
      debugPrint('[*] Admin session revoked on gateway.');
    } catch (_) {
      debugPrint('[*] Revoke call failed — gateway likely already offline.');
    }
  }
}
