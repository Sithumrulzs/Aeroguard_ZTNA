import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/enclave_service.dart';
import '../services/auth_service.dart';
import '../config/transitions.dart';
import 'biometric_auth_screen.dart';
import 'vendor_dashboard.dart';

class HomeLoadPage extends StatefulWidget {
  const HomeLoadPage({super.key});

  @override
  State<HomeLoadPage> createState() => _HomeLoadPageState();
}

class _HomeLoadPageState extends State<HomeLoadPage>
    with TickerProviderStateMixin {
  late AnimationController _logoCtrl;
  late AnimationController _contentCtrl;
  late AnimationController _scanCtrl;
  late Animation<double> _logoOpacity;
  late Animation<double> _logoScale;
  late Animation<double> _contentOpacity;
  late Animation<Offset> _contentSlide;

  String _status = 'INITIALIZING SECURE ENCLAVE';
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();

    _logoCtrl = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );
    _contentCtrl = AnimationController(
      duration: const Duration(milliseconds: 700),
      vsync: this,
    );
    _scanCtrl = AnimationController(
      duration: const Duration(seconds: 4),
      vsync: this,
    )..repeat();

    _logoOpacity = CurvedAnimation(
      parent: _logoCtrl,
      curve: const Interval(0, 0.7, curve: Curves.easeOut),
    );
    _logoScale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoCtrl,
        curve: const Interval(0, 0.7, curve: Curves.easeOutBack),
      ),
    );
    _contentOpacity = CurvedAnimation(
      parent: _contentCtrl,
      curve: Curves.easeOut,
    );
    _contentSlide =
        Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(
          CurvedAnimation(parent: _contentCtrl, curve: Curves.easeOutCubic),
        );

    _logoCtrl.forward();
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _contentCtrl.forward();
    });

    _bootSequence();
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    _contentCtrl.dispose();
    _scanCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootSequence() async {
    // A returning vendor with a still-valid session skips the admin
    // biometric/sign-in path entirely and goes straight back to their
    // dashboard — closing the app shouldn't force them to re-scan the QR
    // for a session that's still perfectly alive on the backend.
    final vendorSession = await AuthService.getVendorSession();
    if (vendorSession != null) {
      try {
        final expires = DateTime.parse(vendorSession['expiresAt']!);
        if (DateTime.now().toUtc().isBefore(expires.toUtc())) {
          await Future.delayed(const Duration(milliseconds: 1200));
          if (mounted) {
            Navigator.pushReplacement(
              context,
              bootToAuthRoute(VendorDashboard(
                vendorName: vendorSession['vendorName']!,
                company:    vendorSession['company']!,
                token:      vendorSession['token']!,
                expiresAt:  vendorSession['expiresAt']!,
              )),
            );
          }
          return;
        }
      } catch (_) {}
      // Unparsable or expired — stale, drop it and fall through to admin flow.
      await AuthService.clearVendorSession();
    }

    // Get authenticated username
    final username = await AuthService.getUsername() ?? 'admin';

    // Phase 1 — initialise enclave
    await Future.delayed(const Duration(milliseconds: 1800));
    await EnclaveService.initializeDevice(username);

    // Phase 2 — hardware key validation
    if (mounted) {
      setState(() {
        _status = 'VALIDATING HARDWARE KEYS';
        _progress = 0.35;
      });
    }
    await Future.delayed(const Duration(milliseconds: 1200));

    // Phase 3 — biometric bridge
    if (mounted) {
      setState(() {
        _status = 'SECURING BIOMETRIC BRIDGE';
        _progress = 0.68;
      });
    }
    await Future.delayed(const Duration(milliseconds: 1100));

    // Phase 4 — ready
    if (mounted) {
      setState(() {
        _status = 'SYSTEM READY';
        _progress = 1.0;
      });
    }
    await Future.delayed(const Duration(milliseconds: 900));

    if (mounted) {
      Navigator.pushReplacement(
        context,
        bootToAuthRoute(const BiometricAuthScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050810),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF050810), Color(0xFF0A1628)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Animated logo ──────────────────────────────────
              AnimatedBuilder(
                animation: _logoCtrl,
                builder: (context, child) => Transform.scale(
                  scale: _logoScale.value,
                  child: Opacity(opacity: _logoOpacity.value, child: child),
                ),
                child: Column(
                  children: [
                    _PremiumLogo(scanAnim: _scanCtrl),
                    const SizedBox(height: 26),
                    const Text(
                      'AEROGUARD',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 9.0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'ZERO TRUST NETWORK ACCESS',
                      style: TextStyle(
                        color: Color(0xFF00C3FF),
                        fontSize: 10,
                        letterSpacing: 3.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 72),

              // ── Progress + status ──────────────────────────────
              FadeTransition(
                opacity: _contentOpacity,
                child: SlideTransition(
                  position: _contentSlide,
                  child: Column(
                    children: [
                      SizedBox(
                        width: 180,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: _progress),
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOut,
                          builder: (context, value, child) =>
                              LinearProgressIndicator(
                                value: value,
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.05,
                                ),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF00C3FF),
                                ),
                                minHeight: 1.5,
                                borderRadius: BorderRadius.circular(8),
                              ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _status,
                          key: ValueKey(_status),
                          style: const TextStyle(
                            color: Color(0xFF475569),
                            fontSize: 10,
                            letterSpacing: 2.5,
                            fontWeight: FontWeight.w500,
                          ),
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

// ── Premium logo badge widget ────────────────────────────────────────────────

class _PremiumLogo extends StatelessWidget {
  final AnimationController scanAnim;

  const _PremiumLogo({required this.scanAnim});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 144,
      width: 144,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ambient outer ring
          CustomPaint(
            size: const Size(144, 144),
            painter: _AmbientRingPainter(),
          ),
          // Rotating scan arc
          AnimatedBuilder(
            animation: scanAnim,
            builder: (context, _) => Transform.rotate(
              angle: scanAnim.value * 2 * pi,
              child: CustomPaint(
                size: const Size(132, 132),
                painter: _ScanArcPainter(),
              ),
            ),
          ),
          // Static inner frame with tick marks
          CustomPaint(
            size: const Size(104, 104),
            painter: _InnerFramePainter(),
          ),
          // Logo
          SizedBox(
            height: 72,
            width: 72,
            child: SvgPicture.asset(
              'assets/images/Colored Logo.svg',
              fit: BoxFit.contain,
            ),
          ),
        ],
      ),
    );
  }
}

class _AmbientRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      center,
      size.width / 2 - 1,
      Paint()
        ..color = const Color(0xFF00C3FF).withValues(alpha: 0.07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ScanArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Track ring
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFF00C3FF).withValues(alpha: 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Gradient sweep arc (120°)
    const sweepAngle = 2 * pi / 3;
    canvas.drawArc(
      rect,
      -pi / 2,
      sweepAngle,
      false,
      Paint()
        ..shader = SweepGradient(
          colors: [
            const Color(0xFF00C3FF).withValues(alpha: 0.0),
            const Color(0xFF00C3FF).withValues(alpha: 0.9),
          ],
          endAngle: sweepAngle,
        ).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round,
    );

    // Bright head dot at arc tip
    const headAngle = -pi / 2 + sweepAngle;
    canvas.drawCircle(
      Offset(
        center.dx + radius * cos(headAngle),
        center.dy + radius * sin(headAngle),
      ),
      2.5,
      Paint()
        ..color = const Color(0xFF00C3FF)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _InnerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Inner circle border
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = const Color(0xFF00C3FF).withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 4 cardinal tick marks
    final tickPaint = Paint()
      ..color = const Color(0xFF00C3FF).withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 4; i++) {
      final angle = i * pi / 2 - pi / 2;
      canvas.drawLine(
        Offset(
          center.dx + (r - 8) * cos(angle),
          center.dy + (r - 8) * sin(angle),
        ),
        Offset(center.dx + r * cos(angle), center.dy + r * sin(angle)),
        tickPaint,
      );
    }

    // 4 small dots at 45° positions
    final dotPaint = Paint()
      ..color = const Color(0xFF00C3FF).withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < 4; i++) {
      final angle = i * pi / 2 + pi / 4 - pi / 2;
      canvas.drawCircle(
        Offset(
          center.dx + (r - 2) * cos(angle),
          center.dy + (r - 2) * sin(angle),
        ),
        1.5,
        dotPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
