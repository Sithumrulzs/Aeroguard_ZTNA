import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';
import 'enclave_service.dart';
import 'location_service.dart';

class NetworkService {
  static final Uri knockUri = Uri.parse(ApiConstants.knockEndpoint);

  /// Executes the Zero Trust network knock.
  /// The gateway has a 30-second anti-replay window; the app enforces a
  /// 10-second connection timeout so it fails fast on unreachable hosts.
  static Future<bool> sendAuthorizationKnock(String username) async {
    // ── DIAGNOSTIC ───────────────────────────────────────────────────────────
    debugPrint('🚨 [DIAGNOSTIC] App is firing packet to: ${knockUri.toString()}');
    debugPrint('🚨 [DIAGNOSTIC] Gateway IP   : ${ApiConstants.gatewayIp}');
    debugPrint('🚨 [DIAGNOSTIC] Gateway Port : ${ApiConstants.gatewayPort}');
    debugPrint('🚨 [DIAGNOSTIC] Username     : $username');
    // ─────────────────────────────────────────────────────────────────────────

    final Map<String, dynamic>? payload =
        await EnclaveService.generateZeroTrustPayload(username);

    if (payload == null) {
      debugPrint('🚨 [DIAGNOSTIC] Enclave payload is NULL — device not provisioned yet.');
      debugPrint('[-] Aborting: enclave payload generation failed.');
      return false;
    }

    debugPrint('🚨 [DIAGNOSTIC] Device ID  : ${payload['device_id']}');
    debugPrint('🚨 [DIAGNOSTIC] Timestamp  : ${payload['timestamp']}');
    debugPrint('🚨 [DIAGNOSTIC] Signature  : ${(payload['signature'] as String).substring(0, 16)}...');

    // GPS must NOT block the knock — send the packet immediately.
    // Location is pushed to the central auth server after the knock completes.
    final body = <String, dynamic>{
      ...payload,
      'telemetry': const <String, dynamic>{},
    };

    try {
      debugPrint('🚨 [DIAGNOSTIC] Sending HTTP POST now...');
      final response = await http
          .post(
            knockUri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(
            Duration(seconds: ApiConstants.connectionTimeoutSeconds),
          );

      debugPrint('🚨 [DIAGNOSTIC] Response status : ${response.statusCode}');
      debugPrint('🚨 [DIAGNOSTIC] Response body   : ${response.body}');

      if (response.statusCode == 200) {
        debugPrint('[+] KNOCK ACCEPTED — gateway open.');
        // Fire-and-forget: push GPS after the knock so it never delays the tunnel.
        LocationService.sendToBackend(username);
        return true;
      }
      debugPrint(
        '[-] KNOCK DENIED — HTTP ${response.statusCode}: ${response.body}',
      );
      return false;
    } catch (e) {
      debugPrint('🚨 [DIAGNOSTIC] EXCEPTION caught: $e');
      debugPrint('[-] NETWORK ERROR — could not reach gateway: $e');
      return false;
    }
  }
}
