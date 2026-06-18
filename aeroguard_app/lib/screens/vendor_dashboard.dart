import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';
import '../services/location_service.dart';
import '../widgets/vendor_countdown_timer.dart';
import '../config/transitions.dart';
import 'sign_in_page.dart';

enum _VKnockStatus { idle, knocking, success, pendingDevice, deviceApproved, deviceDenied, failed }

class VendorDashboard extends StatefulWidget {
  final String vendorName;
  final String company;
  final String token;
  final String expiresAt;

  const VendorDashboard({
    super.key,
    required this.vendorName,
    required this.company,
    required this.token,
    required this.expiresAt,
  });

  @override
  State<VendorDashboard> createState() => _VendorDashboardState();
}

class _VendorDashboardState extends State<VendorDashboard> {
  _VKnockStatus _knockStatus = _VKnockStatus.idle;
  Timer? _devicePollTimer;
  String _deviceIp         = '';
  bool   _pollInFlight     = false;   // prevents overlapping async poll calls
  bool   _terminating      = false;   // prevents double dialog + navigation

  @override
  void dispose() {
    _devicePollTimer?.cancel();
    super.dispose();
  }

  int _remainingSeconds() {
    try {
      final expiry = DateTime.parse(widget.expiresAt).toUtc();
      final diff = expiry.difference(DateTime.now().toUtc());
      return diff.inSeconds.clamp(0, 99999);
    } catch (_) {
      return 0;
    }
  }

  String _expiryLabel() {
    try {
      final expiry = DateTime.parse(widget.expiresAt).toLocal();
      final h = expiry.hour.toString().padLeft(2, '0');
      final m = expiry.minute.toString().padLeft(2, '0');
      return 'UNTIL $h:$m';
    } catch (_) {
      return 'LIMITED';
    }
  }

  Future<void> _handleVendorKnock() async {
    setState(() => _knockStatus = _VKnockStatus.knocking);
    try {
      // ── 1. UDP knock → port 7777 ─────────────────────────────────────────
      // Sniffer validates token + injects iptables rule before HTTP arrives.
      try {
        final udpBody = utf8.encode(jsonEncode({
          'type':        'vendor_knock',
          'token_hash':  widget.token,
          'vendor_name': widget.vendorName,
        }));
        final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        sock.send(udpBody,
                  InternetAddress(ApiConstants.gatewayIp),
                  ApiConstants.udpKnockPort);
        sock.close();
      } catch (_) {}

      // ── 2. Wait for sniffer to open port 8000 ────────────────────────────
      await Future.delayed(const Duration(seconds: 2));

      // ── 3. HTTP POST — bind TOFU + retrieve session details ──────────────
      final position = await LocationService.getPosition();
      final response = await http
          .post(
            Uri.parse(ApiConstants.vendorKnockEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token_hash':  widget.token,
              'vendor_name': widget.vendorName,
              if (position != null) 'latitude':  position.latitude,
              if (position != null) 'longitude': position.longitude,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() => _knockStatus = _VKnockStatus.success);
        _startDevicePolling();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'TUNNEL AUTHORIZED — Vendor session active',
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                letterSpacing: 0.3,
              ),
            ),
            backgroundColor: Colors.orangeAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
          ),
        );
      } else {
        setState(() => _knockStatus = _VKnockStatus.failed);
        Map<String, dynamic> body = {};
        try {
          body = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {}
        _showKnockError(body['detail']?.toString() ?? 'Tunnel authorization failed.');
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) setState(() => _knockStatus = _VKnockStatus.idle);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _knockStatus = _VKnockStatus.failed);
        _showKnockError('Gateway unreachable. Ensure you are on the AeroGuard network.');
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) setState(() => _knockStatus = _VKnockStatus.idle);
      }
    }
  }

  void _showKnockError(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1421),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.block, color: Colors.redAccent, size: 20),
            SizedBox(width: 10),
            Text('Access Denied', style: TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(color: Color(0xFFC0C7D4), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'OK',
              style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _startDevicePolling() {
    _devicePollTimer?.cancel();
    _devicePollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      // Skip if a previous call is still in-flight (slow network) or session is
      // already being terminated to prevent overlapping dialogs / double-pop.
      if (_pollInFlight || _terminating) return;
      _pollInFlight = true;
      try {
        final uri = Uri.parse(
            '${ApiConstants.vendorDeviceStatusEndpoint}?token=${widget.token}');
        final res = await http.get(uri).timeout(const Duration(seconds: 6));
        if (!mounted) { _pollInFlight = false; return; }

        if (res.statusCode == 200) {
          final data     = jsonDecode(res.body) as Map<String, dynamic>;
          final status   = data['status']          as String? ?? '';
          final approved = data['device_approved'] == true;
          final deviceIp = data['device_ip']       as String? ?? '';

          if (approved) {
            // Keep timer running after approval so we detect future revocation.
            if (_knockStatus != _VKnockStatus.deviceApproved) {
              setState(() {
                _knockStatus = _VKnockStatus.deviceApproved;
                _deviceIp    = deviceIp;
              });
            } else if (deviceIp.isNotEmpty && _deviceIp != deviceIp) {
              // IP may have arrived on a later poll (DB write race on first tick)
              setState(() => _deviceIp = deviceIp);
            }
          } else if (status == 'pending_device_approval') {
            if (_knockStatus != _VKnockStatus.pendingDevice) {
              setState(() => _knockStatus = _VKnockStatus.pendingDevice);
            }
          } else if (status == 'expired' || status == 'revoked') {
            _terminating = true;
            _devicePollTimer?.cancel();
            if (mounted) {
              await showDialog(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF0D1421),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                  title: const Text(
                    'SESSION TERMINATED',
                    style: TextStyle(
                        color: Color(0xFFEF4444),
                        fontSize: 13,
                        letterSpacing: 2.0,
                        fontWeight: FontWeight.bold),
                  ),
                  content: Text(
                    status == 'revoked'
                        ? 'Your access has been revoked by the administrator.'
                        : 'Your access session has expired.',
                    style: const TextStyle(
                        color: Color(0xFF94A3B8), fontSize: 13, height: 1.5),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK',
                          style: TextStyle(
                              color: Color(0xFFEF4444), letterSpacing: 1.0)),
                    ),
                  ],
                ),
              );
              if (mounted) {
                Navigator.pushReplacement(
                    context, fadeRoute(const SignInPage()));
              }
            }
          } else if (status == 'active' &&
              _knockStatus == _VKnockStatus.pendingDevice &&
              deviceIp.isEmpty) {
            // Admin denied: pending_device_ip cleared to NULL
            _devicePollTimer?.cancel();
            setState(() => _knockStatus = _VKnockStatus.deviceDenied);
          }
        } else if (res.statusCode == 404) {
          _devicePollTimer?.cancel();
        }
      } catch (_) {}
      _pollInFlight = false;
    });
  }

  Color get _statusColor => switch (_knockStatus) {
    _VKnockStatus.success        => const Color(0xFF10B981),
    _VKnockStatus.pendingDevice  => Colors.orangeAccent,
    _VKnockStatus.deviceApproved => const Color(0xFF10B981),
    _VKnockStatus.deviceDenied   => const Color(0xFFEF4444),
    _VKnockStatus.failed         => const Color(0xFFEF4444),
    _                            => Colors.orangeAccent,
  };

  String get _statusLabel => switch (_knockStatus) {
    _VKnockStatus.idle           => 'TAP TO INITIATE TUNNEL',
    _VKnockStatus.knocking       => 'ESTABLISHING TUNNEL...',
    _VKnockStatus.success        => 'TUNNEL ACTIVE — CONNECTING DEVICE...',
    _VKnockStatus.pendingDevice  => 'AWAITING ADMIN DEVICE APPROVAL',
    _VKnockStatus.deviceApproved => 'DEVICE APPROVED',
    _VKnockStatus.deviceDenied   => 'DEVICE ACCESS DENIED BY ADMIN',
    _VKnockStatus.failed         => 'ACCESS DENIED',
  };

  @override
  Widget build(BuildContext context) {
    final isSuccess = _knockStatus == _VKnockStatus.success ||
        _knockStatus == _VKnockStatus.pendingDevice ||
        _knockStatus == _VKnockStatus.deviceApproved ||
        _knockStatus == _VKnockStatus.deviceDenied;

    return Scaffold(
      backgroundColor: const Color(0xFF050810),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF050810), Color(0xFF0A1628)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header bar ────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 16),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.35)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 14),
                            SizedBox(width: 6),
                            Text(
                              'RESTRICTED ACCESS',
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.pushReplacement(context, fadeRoute(const SignInPage())),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D1421),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
                          ),
                          child: const Icon(Icons.logout, color: Color(0xFF475569), size: 16),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Vendor identity card ──────────────────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1421),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        height: 42,
                        width: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.orangeAccent.withValues(alpha: 0.1),
                          border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
                        ),
                        child: const Center(
                          child: Icon(Icons.person_outline, color: Colors.orangeAccent, size: 20),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.vendorName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 1),
                            Text(
                              widget.company,
                              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          _expiryLabel(),
                          style: const TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Central knock button — always at center ───────────────
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _VendorKnockButton(
                          status: _knockStatus,
                          onTap: _knockStatus == _VKnockStatus.idle
                              ? _handleVendorKnock
                              : null,
                        ),
                        const SizedBox(height: 22),
                        // Post-knock: live countdown; otherwise: status label
                        if (_knockStatus == _VKnockStatus.deviceApproved) ...[
                          VendorCountdownTimer(
                            initialSeconds: _remainingSeconds(),
                            onExpire: () {
                              if (_terminating || !mounted) return;
                              _terminating = true;
                              _devicePollTimer?.cancel();
                              Navigator.pushReplacement(
                                  context, fadeRoute(const SignInPage()));
                            },
                          ),
                        ] else
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: Text(
                              _statusLabel,
                              key: ValueKey(_knockStatus),
                              style: TextStyle(
                                color: _statusColor.withValues(alpha: 0.75),
                                fontSize: 11,
                                letterSpacing: 2.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // ── Post-knock: info chips + TUNNEL ACTIVE badge ──────────
                if (isSuccess) ...[
                  Row(
                    children: [
                      _InfoChip(icon: Icons.visibility_outlined, label: 'MONITORED'),
                      const SizedBox(width: 8),
                      _InfoChip(icon: Icons.save_outlined, label: 'LOGGED'),
                      const SizedBox(width: 8),
                      _InfoChip(icon: Icons.access_time, label: 'JIT ACCESS'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    height: 52,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: _knockStatus == _VKnockStatus.deviceApproved
                          ? const Color(0xFF10B981).withValues(alpha: 0.08)
                          : _knockStatus == _VKnockStatus.deviceDenied
                              ? const Color(0xFFEF4444).withValues(alpha: 0.08)
                              : Colors.orangeAccent.withValues(alpha: 0.06),
                      border: Border.all(
                        color: _knockStatus == _VKnockStatus.deviceApproved
                            ? const Color(0xFF10B981).withValues(alpha: 0.40)
                            : _knockStatus == _VKnockStatus.deviceDenied
                                ? const Color(0xFFEF4444).withValues(alpha: 0.40)
                                : Colors.orangeAccent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _knockStatus == _VKnockStatus.deviceApproved
                                ? Icons.check_circle_outline
                                : _knockStatus == _VKnockStatus.deviceDenied
                                    ? Icons.block_outlined
                                    : Icons.pending_outlined,
                            color: _knockStatus == _VKnockStatus.deviceApproved
                                ? const Color(0xFF10B981)
                                : _knockStatus == _VKnockStatus.deviceDenied
                                    ? const Color(0xFFEF4444)
                                    : Colors.orangeAccent,
                            size: 16,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _knockStatus == _VKnockStatus.deviceApproved
                                ? (_deviceIp.isNotEmpty
                                    ? 'CONNECTED  ·  $_deviceIp'
                                    : 'DEVICE CONNECTED')
                                : _knockStatus == _VKnockStatus.deviceDenied
                                    ? 'DEVICE ACCESS DENIED'
                                    : 'AWAITING DEVICE APPROVAL',
                            style: TextStyle(
                              color: _knockStatus == _VKnockStatus.deviceApproved
                                  ? const Color(0xFF10B981)
                                  : _knockStatus == _VKnockStatus.deviceDenied
                                      ? const Color(0xFFEF4444)
                                      : Colors.orangeAccent,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Pulsing circular knock button (orange theme) ──────────────────────────────
class _VendorKnockButton extends StatefulWidget {
  final _VKnockStatus status;
  final VoidCallback? onTap;

  const _VendorKnockButton({required this.status, required this.onTap});

  @override
  State<_VendorKnockButton> createState() => _VendorKnockButtonState();
}

class _VendorKnockButtonState extends State<_VendorKnockButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _color => switch (widget.status) {
    _VKnockStatus.success        => const Color(0xFF10B981),
    _VKnockStatus.deviceApproved => const Color(0xFF10B981),
    _VKnockStatus.deviceDenied   => const Color(0xFFEF4444),
    _VKnockStatus.failed         => const Color(0xFFEF4444),
    _                            => Colors.orangeAccent,
  };

  @override
  Widget build(BuildContext context) {
    final color = _color;

    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => SizedBox(
          height: 220,
          width: 220,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Ring 3 — outermost, faintest
              Container(
                height: 202 + _pulse.value * 10,
                width:  202 + _pulse.value * 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.06 + _pulse.value * 0.05),
                    width: 1,
                  ),
                ),
              ),
              // Ring 2
              Container(
                height: 164 + _pulse.value * 7,
                width:  164 + _pulse.value * 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.12 + _pulse.value * 0.10),
                    width: 1,
                  ),
                ),
              ),
              // Ring 1 — innermost halo
              Container(
                height: 126 + _pulse.value * 4,
                width:  126 + _pulse.value * 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.20 + _pulse.value * 0.15),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.04 + _pulse.value * 0.08),
                      blurRadius: 28,
                      spreadRadius: 4,
                    ),
                  ],
                ),
              ),
              // Center button
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                height: 112,
                width:  112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.3, -0.3),
                    radius: 1,
                    colors: [
                      color.withValues(alpha: 0.28),
                      color.withValues(alpha: 0.08),
                    ],
                  ),
                  border: Border.all(color: color.withValues(alpha: 0.7), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.20 + _pulse.value * 0.16),
                      blurRadius: 36,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.status == _VKnockStatus.knocking)
                        SizedBox(
                          height: 30,
                          width: 30,
                          child: CircularProgressIndicator(color: color, strokeWidth: 2),
                        )
                      else
                        SvgPicture.asset(
                          'assets/images/Light Logo.svg',
                          height: 30,
                          width: 30,
                          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                        ),
                      const SizedBox(height: 7),
                      Text(
                        switch (widget.status) {
                          _VKnockStatus.success        => 'TUNNEL\nACTIVE',
                          _VKnockStatus.pendingDevice  => 'AWAITING\nAPPROVAL',
                          _VKnockStatus.deviceApproved => 'DEVICE\nCONNECTED',
                          _VKnockStatus.deviceDenied   => 'DEVICE\nDENIED',
                          _VKnockStatus.failed         => 'ACCESS\nDENIED',
                          _VKnockStatus.knocking       => 'CONNECTING\n...',
                          _VKnockStatus.idle           => 'AUTHORIZE\nTUNNEL',
                        },
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: color,
                          fontSize: 7.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: Colors.orangeAccent.withValues(alpha: 0.7)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: Colors.orangeAccent.withValues(alpha: 0.7),
              fontSize: 9,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
