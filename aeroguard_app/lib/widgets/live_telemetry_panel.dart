import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';
import 'dashboard_panel.dart';

class LiveTelemetryPanel extends StatefulWidget {
  const LiveTelemetryPanel({super.key});

  @override
  State<LiveTelemetryPanel> createState() => _LiveTelemetryPanelState();
}

class _LiveTelemetryPanelState extends State<LiveTelemetryPanel> {
  Timer? _timer;

  int    _registeredAdmins = 0;
  int    _activeVendors    = 0;
  String _gatewayStatus    = 'SECURED';
  String _registeredLabel  = '—';
  String _vendorLabel      = 'Idle';
  String _lastKnock        = '—';
  bool   _loading          = true;
  bool   _error            = false;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _fetch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // UTC ISO string → Asia/Colombo (UTC+5:30) formatted label
  String _toColombTime(String isoUtc) {
    try {
      final colombo = DateTime.parse(isoUtc).toUtc()
          .add(const Duration(hours: 5, minutes: 30));
      final h = colombo.hour.toString().padLeft(2, '0');
      final m = colombo.minute.toString().padLeft(2, '0');
      const months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[colombo.month - 1]} ${colombo.day}  $h:$m';
    } catch (_) {
      return '—';
    }
  }

  Future<void> _fetch() async {
    try {
      final response = await http
          .get(Uri.parse(ApiConstants.dashboardTelemetryEndpoint))
          .timeout(const Duration(seconds: 25));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        final vendorNames = List<String>.from(data['active_vendor_names'] ?? []);
        final lastKnockAt = data['last_knock_at'] as String?;

        setState(() {
          _registeredAdmins = ((data['registered_admins'] ??
                                data['active_admins']) as num?)?.toInt() ?? 0;
          _activeVendors    = (data['active_vendors'] as num?)?.toInt() ?? 0;
          _gatewayStatus    = data['gateway_status'] ?? 'SECURED';
          _registeredLabel  = _registeredAdmins.toString();
          _vendorLabel      = vendorNames.isEmpty
              ? '$_activeVendors · Idle'
              : '$_activeVendors · ${vendorNames.join(', ')}';
          _lastKnock        = lastKnockAt != null ? _toColombTime(lastKnockAt) : '—';
          _loading          = false;
          _error            = false;
        });
      } else {
        if (mounted) setState(() { _error = true; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _error = true; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DashboardPanel(
      title: 'Network Telemetry',
      icon: Icons.radar,
      child: _loading
          ? const Center(
              child: SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00C3FF)),
                ),
              ),
            )
          : Column(
              children: [
                _TelemetryRow(
                  label: 'Registered Admins',
                  value: _error ? '—' : _registeredLabel,
                  statusColor: _registeredAdmins > 0
                      ? const Color(0xFF10B981)
                      : const Color(0xFF475569),
                ),
                const SizedBox(height: 14),
                _TelemetryRow(
                  label: 'Active Vendors',
                  value: _error ? '—' : _vendorLabel,
                  statusColor: _activeVendors > 0
                      ? Colors.orangeAccent
                      : const Color(0xFF475569),
                ),
                const SizedBox(height: 14),
                _TelemetryRow(
                  label: 'Gateway',
                  value: _error ? 'OFFLINE' : _gatewayStatus,
                  statusColor: _error
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF00C3FF),
                ),
                const SizedBox(height: 14),
                _TelemetryRow(
                  label: 'Last Knock',
                  value: _lastKnock,
                  statusColor: const Color(0xFF475569),
                ),
              ],
            ),
    );
  }
}

class _TelemetryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color  statusColor;

  const _TelemetryRow({
    required this.label,
    required this.value,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: 13,
            fontWeight: FontWeight.w400,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 7,
              width: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor,
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withValues(alpha: 0.5),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
