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
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    _initialized = true;
  }

  /// Fires once a vendor's laptop is actually paired via QR — purely an
  /// alert that something needs the admin's attention. Approve/Decline
  /// happen from the reliable in-app card on the dashboard, not from
  /// notification action buttons: those proved unreliable in testing (a
  /// tap aimed at "Approve" registered in adb logcat as a plain
  /// SELECT_NOTIFICATION body-open rather than the action-specific
  /// intent — the OS peek/collapsed notification view on some Android
  /// builds doesn't seem to route touches to action buttons correctly).
  /// Tapping this notification just opens the app, which does work
  /// reliably, landing the admin on the dashboard where the card lives.
  static Future<void> showVendorDeviceAlert({
    required String vendorName,
    required String company,
    required String deviceIp,
    required String deviceMac,
  }) async {
    await init();
    const androidDetails = AndroidNotificationDetails(
      'aeroguard_alerts',
      'AeroGuard Security Alerts',
      channelDescription: 'Vendor device approval requests',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFF00C3FF),
      enableVibration: true,
      playSound: true,
    );
    final body = '$vendorName ($company)\n'
        'IP: $deviceIp   MAC: ${deviceMac.isNotEmpty ? deviceMac : "—"}\n'
        'Open the app to approve or decline.';
    await _plugin.show(
      vendorName.hashCode,
      'Device Access Request',
      body,
      const NotificationDetails(android: androidDetails),
    );
  }

  /// Clears a device-request alert once it's been handled (approved,
  /// declined, or the pending record disappeared entirely — e.g. expired)
  /// so a stale notification never sits in the shade pointing at a
  /// request that's no longer actionable.
  static Future<void> cancelVendorDeviceAlert(String vendorName) async {
    await init();
    await _plugin.cancel(vendorName.hashCode);
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
