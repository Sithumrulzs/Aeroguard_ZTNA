import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';

/// Handles the "Approve" / "Decline" taps on a vendor device notification —
/// works whether the app is foregrounded, backgrounded, or the notification
/// is acted on without ever opening the app at all.
@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  await _handleVendorDeviceAction(response);
}

// Must be awaited all the way through — a background isolate can be torn
// down the instant this function returns, so a fire-and-forget HTTP call
// here would frequently never actually reach the network.
Future<void> _handleVendorDeviceAction(NotificationResponse response) async {
  if (response.actionId != 'approve' && response.actionId != 'decline') {
    return; // body tap, not an action button — let the app open normally
  }
  if (response.payload == null) return;
  try {
    final data = jsonDecode(response.payload!) as Map<String, dynamic>;
    final tokenHash = data['token_hash'] as String? ?? '';
    if (tokenHash.isEmpty) return;
    await http
        .post(
          Uri.parse(ApiConstants.approveVendorDeviceEndpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'token_hash':     tokenHash,
            'admin_username': data['admin_username'] as String? ?? 'admin',
            'approved':       response.actionId == 'approve',
          }),
        )
        .timeout(const Duration(seconds: 10));
  } catch (_) {}
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings =
        InitializationSettings(android: android);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleVendorDeviceAction,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    _initialized = true;
  }

  /// Fires an actionable alert the moment a vendor device is detected on
  /// the gateway's LAN, before it is ever allowed to connect — the admin
  /// can Approve/Decline straight from the notification shade, or tap the
  /// body to open the full device card (with MAC override / network scan).
  static Future<void> showVendorDeviceAlert({
    required String vendorName,
    required String company,
    required String deviceIp,
    required String deviceMac,
    required String tokenHash,
    required String adminUsername,
  }) async {
    await init();
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'aeroguard_alerts',
      'AeroGuard Security Alerts',
      channelDescription: 'Vendor device approval requests',
      importance: Importance.high,
      priority: Priority.high,
      color: const Color(0xFF00C3FF),
      enableVibration: true,
      playSound: true,
      actions: const [
        AndroidNotificationAction('approve', 'Approve',
            showsUserInterface: false, cancelNotification: true),
        AndroidNotificationAction('decline', 'Decline',
            showsUserInterface: false, cancelNotification: true),
      ],
    );
    final NotificationDetails details =
        NotificationDetails(android: androidDetails);
    await _plugin.show(
      vendorName.hashCode,
      'Device Access Request',
      '$vendorName ($company)\nIP: $deviceIp   MAC: $deviceMac',
      details,
      payload: jsonEncode({
        'token_hash':     tokenHash,
        'admin_username': adminUsername,
      }),
    );
  }
}
