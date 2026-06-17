import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
    await _plugin.initialize(settings);
    // Request permission on Android 13+
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    _initialized = true;
  }

  static Future<void> showVendorDeviceAlert({
    required String vendorName,
    required String company,
    required String deviceIp,
    required String deviceMac,
  }) async {
    await init();
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'aeroguard_alerts',
      'AeroGuard Security Alerts',
      channelDescription: 'Vendor device approval requests',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFFFF9800),
      enableVibration: true,
      playSound: true,
    );
    const NotificationDetails details =
        NotificationDetails(android: androidDetails);
    await _plugin.show(
      vendorName.hashCode,
      'Device Access Request',
      '$vendorName ($company) wants to connect — $deviceIp',
      details,
    );
  }
}
