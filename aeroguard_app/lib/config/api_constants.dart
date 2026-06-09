class ApiConstants {
  // ——— Kali Gateway – iptables / knock enforcement (Local Data Plane) ———
  static const String gatewayIp = "192.168.100.130";
  static const String gatewayPort = "8000";
  static const String baseUrl = "http://$gatewayIp:$gatewayPort/api/v1";

  static const String knockEndpoint = "$baseUrl/knock";
  static const String vendorKnockEndpoint = "$baseUrl/vendor_knock";
  static const String provisionVendorEndpoint = "$baseUrl/provision-vendor";

  // ——— Central Auth – identity / login (WSO2 Cloud Control Plane) ———
  // PASTE YOUR LIVE CHOREO HTTPS URL HERE (Remove the trailing slash if necessary)
  static const String centralAuthUrl =
      "https://69e1efef-e429-472f-bfce-68e0ac0360ff-dev.e1-us-east-azure.choreoapis.dev/default/backendcentralauth/v1.0";

  static const String loginEndpoint          = "$centralAuthUrl/api/v1/auth/login";
  static const String registerDeviceEndpoint = "$centralAuthUrl/api/v1/auth/register-device";
  static const String adminResetDeviceEndpoint = "$centralAuthUrl/api/v1/auth/admin/reset-device";

  static const String dashboardStatsEndpoint =
      "$centralAuthUrl/api/v1/dashboard/stats";
  static const String dashboardTelemetryEndpoint =
      "$centralAuthUrl/api/v1/dashboard/telemetry";

  // ——— Timeouts ———
  static const int connectionTimeoutSeconds = 15;
}
