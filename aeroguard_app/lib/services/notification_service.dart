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

  /// Fires the moment a vendor knocks. Always shows the vendor's details
  /// and device IP/MAC (pending placeholder until the laptop is paired),
  /// with both Approve and Decline beneath — approving before a device is
  /// actually paired is harmlessly rejected server-side, so there's no
  /// need to hide the button while waiting.
  static Future<void> showVendorDeviceAlert({
    required String vendorName,
    required String company,
    required String deviceIp,
    required String deviceMac,
    required String tokenHash,
    required String adminUsername,
  }) async {
    await init();
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'aeroguard_alerts',
      'AeroGuard Security Alerts',
      channelDescription: 'Vendor device approval requests',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFF00C3FF),
      enableVibration: true,
      playSound: true,
      actions: [
        AndroidNotificationAction('approve', 'Approve',
            showsUserInterface: false, cancelNotification: true),
        AndroidNotificationAction('decline', 'Decline',
            showsUserInterface: false, cancelNotification: true),
      ],
    );
    const NotificationDetails details =
        NotificationDetails(android: androidDetails);
    final body = '$vendorName ($company)\n'
        'IP: ${deviceIp.isNotEmpty ? deviceIp : "Pending..."}   '
        'MAC: ${deviceMac.isNotEmpty ? deviceMac : "Pending..."}';
    await _plugin.show(
      vendorName.hashCode,
      'Device Access Request',
      body,
      details,
      payload: jsonEncode({
        'token_hash':     tokenHash,
        'admin_username': adminUsername,
      }),
    );
  }

  /// Purely informational — fires once a vendor's device is actually
  /// granted full access, so the admin sees a clear record of who connected
  /// and from where without needing to act on anything.
  static Future<void> showVendorConnectedAlert({
    required String vendorName,
    required String ip,
    required String mac,
  }) async {
    await init();
    const androidDetails = AndroidNotificationDetails(
      'aeroguard_alerts',
      'AeroGuard Security Alerts',
      channelDescription: 'Vendor connection activity',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      color: Color(0xFF10B981),
      enableVibration: false,
      playSound: false,
    );
    await _plugin.show(
      'connected_$vendorName'.hashCode,
      'Vendor Connected',
      mac.isNotEmpty
          ? '$vendorName — IP: $ip   MAC: $mac'
          : '$vendorName — IP: $ip',
      const NotificationDetails(android: androidDetails),
    );
  }

  /// Purely informational — fires on a denied/failed knock attempt, so a
  /// rejected vendor isn't invisible just because nothing came of it.
  static Future<void> showVendorFailedAlert({
    required String vendorName,
    required String reason,
  }) async {
    await init();
    const androidDetails = AndroidNotificationDetails(
      'aeroguard_alerts',
      'AeroGuard Security Alerts',
      channelDescription: 'Vendor connection activity',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFFEF4444),
      enableVibration: true,
      playSound: false,
    );
    await _plugin.show(
      'failed_$vendorName${DateTime.now().millisecondsSinceEpoch}'.hashCode,
      'Vendor Connection Failed',
      '$vendorName — $reason',
      const NotificationDetails(android: androidDetails),
    );
  }
}
