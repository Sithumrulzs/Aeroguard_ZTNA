import 'dart:convert';
import 'package:http/http.dart' as http;

/// Talks to the Render-hosted central_auth backend with automatic retry.
///
/// Render's free tier spins the service down after ~15 min idle, so the
/// next request pays a cold-start penalty that can occasionally run past
/// even a generous single timeout — and separately, a dropped or flaky
/// connection attempt (unrelated to cold start) looks identical to the
/// caller. One big timeout makes the user wait a long time doing nothing
/// on a genuine failure; three independent attempts recovers from both
/// cases — and when an earlier attempt was actually a cold start, the
/// server keeps booting in the background regardless of the client
/// giving up on it, so a later attempt often lands fast against an
/// now-warm instance.
class CentralAuthHttp {
  static const _timeouts = [
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
  ];

  static Future<http.Response> post(Uri uri, {required Map<String, dynamic> body}) {
    final encoded = jsonEncode(body);
    return _withRetry(() => http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: encoded,
        ));
  }

  static Future<http.Response> get(Uri uri) => _withRetry(() => http.get(uri));

  static Future<http.Response> _withRetry(
      Future<http.Response> Function() attempt) async {
    Object lastError = Exception('unreachable');
    for (final timeout in _timeouts) {
      try {
        return await attempt().timeout(timeout);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError;
  }
}
