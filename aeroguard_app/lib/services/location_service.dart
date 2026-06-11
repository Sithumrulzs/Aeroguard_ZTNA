import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';

class LocationService {
  /// Returns the device's current GPS position.
  /// Returns null if permission is denied, revoked, or the service is off.
  static Future<Position?> getPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Fire-and-forget: gets location and PATCHes it to the central auth backend.
  /// Silently swallows all errors — location is best-effort telemetry.
  static Future<void> sendToBackend(String username) async {
    try {
      final position = await getPosition();
      if (position == null) return;

      await http
          .post(
            Uri.parse(ApiConstants.updateLocationEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username':  username,
              'latitude':  position.latitude,
              'longitude': position.longitude,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[LocationService] user update skipped: $e');
    }
  }

  /// Fire-and-forget: captures GPS at vendor QR-scan time and stores it
  /// against the vendor session in Supabase via the central auth backend.
  static Future<void> sendVendorLocation(String tokenHash) async {
    try {
      final position = await getPosition();
      if (position == null) return;

      await http
          .post(
            Uri.parse(ApiConstants.updateVendorLocationEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token_hash': tokenHash,
              'latitude':   position.latitude,
              'longitude':  position.longitude,
            }),
          )
          .timeout(const Duration(seconds: 8));
      debugPrint('[LocationService] vendor location recorded');
    } catch (e) {
      debugPrint('[LocationService] vendor update skipped: $e');
    }
  }
}
