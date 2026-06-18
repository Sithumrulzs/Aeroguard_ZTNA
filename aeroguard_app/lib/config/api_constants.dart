class ApiConstants {
  // ——— Kali Gateway – iptables / knock enforcement (Local Data Plane) ———
  static const String gatewayIp = "192.168.100.130";
  static const String gatewayPort = "8000";
  static const String baseUrl = "http://$gatewayIp:$gatewayPort/api/v1";

  static const String gatewayHealthUrl = "http://$gatewayIp:$gatewayPort/health";
  static const int    udpKnockPort  = 7777;
  static const String knockEndpoint = "$baseUrl/knock";
  static const String vendorKnockEndpoint = "$baseUrl/vendor_knock";
  static const String revokeAdminSessionEndpoint = "$baseUrl/revoke-admin-session";
  static const String networkScanEndpoint         = "$baseUrl/network/scan";

  // ——— Central Auth – vendor provisioning (cloud, works off-network) ———

  static const String vendorProvisionEndpoint =
      "$centralAuthUrl/api/v1/provision-vendor";

  // ——— Central Auth – identity / login (Render cloud backend) ———
  static const String centralAuthUrl = "https://aeroguard-ztna.onrender.com";

  static const String loginEndpoint = "$centralAuthUrl/api/v1/auth/login";
  static const String registerDeviceEndpoint =
      "$centralAuthUrl/api/v1/auth/register-device";
  static const String adminResetDeviceEndpoint =
      "$centralAuthUrl/api/v1/auth/admin/reset-device";

  static const String dashboardStatsEndpoint =
      "$centralAuthUrl/api/v1/dashboard/stats";
  static const String gatewayThreatsEndpoint =
      "$centralAuthUrl/api/v1/dashboard/threats";
  static const String dashboardTelemetryEndpoint =
      "$centralAuthUrl/api/v1/dashboard/telemetry";
  static const String vendorSessionsEndpoint =
      "$centralAuthUrl/api/v1/dashboard/vendor-sessions";
  static const String revokeVendorEndpoint =
      "$centralAuthUrl/api/v1/admin/revoke-vendor";
  static const String updateLocationEndpoint =
      "$centralAuthUrl/api/v1/auth/update-location";
  static const String updateVendorLocationEndpoint =
      "$centralAuthUrl/api/v1/vendor/update-location";

  // ——— Vendor device approval ———
  static const String pendingVendorDevicesEndpoint =
      "$centralAuthUrl/api/v1/dashboard/pending-vendor-devices";
  static const String approveVendorDeviceEndpoint =
      "$centralAuthUrl/api/v1/admin/approve-vendor-device";
  static const String vendorDeviceStatusEndpoint =
      "$centralAuthUrl/api/v1/vendor/device-status";

  // ——— Timeouts ———
  static const int connectionTimeoutSeconds = 15;
}
