import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/biometric_service.dart';
import '../services/enclave_service.dart';
import '../services/auth_service.dart';
import '../config/transitions.dart';
import 'biometric_auth_screen.dart';
import 'intro_video_screen.dart';
import 'sign_in_page.dart';
import 'vendor_dashboard.dart';

// Boot-screen background — also referenced by IntroVideoScreen so its
// color-match handoff overlay is pixel-identical, never a second
// hardcoded hex.
const Color kHomeLoadBackgroundColor = Color(0xFF050810);

class HomeLoadPage extends StatefulWidget {
  const HomeLoadPage({super.key, this.fromVideo = false});

  /// True only when reached from IntroVideoScreen's color-matched handoff.
  /// The badge/wordmark entrance itself is unchanged either way; this just
  /// removes the extra 500ms stagger before the status/progress block, so
  /// everything fades in together as the video's own background fade is
  /// still settling instead of a beat later. Direct launches (and the
  /// reduce-motion path) leave this false and keep that original stagger.
  final bool fromVideo;

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
    );

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

    // Badge/wordmark entrance is always the original pop+fade — unchanged.
    _scanCtrl.repeat();
    _logoCtrl.forward();

    // The status/progress block still fades in after the badge, except
    // when arriving from the video: there it starts at the same time as
    // everything else instead of a beat later, so it fades in alongside
    // the tail of the video's own background transition rather than after
    // it's already settled.
    if (widget.fromVideo) {
      _contentCtrl.forward();
    } else {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _contentCtrl.forward();
      });
    }

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
    // Kicked off immediately — not after the boot delays below — so this
    // resolves for free while Phase 1-4 run their course and the final
    // routing decision costs no extra wall-clock time.
    final authDestinationFuture = _resolveAuthDestination();

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

    // Phase 1 — initialise enclave (IntroVideoScreen already kicked this off
    // so the video's runtime doubles as loading time; reuse that future
    // instead of running the isolate-heavy init a second time, falling back
    // to starting it here if that screen was skipped).
    await Future.delayed(const Duration(milliseconds: 1800));
    await (IntroVideoScreen.enclaveInitFuture ??=
        EnclaveService.initializeDevice(username));

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

    final destination = await authDestinationFuture;
    if (mounted) {
      Navigator.pushReplacement(context, bootToAuthRoute(destination));
    }
  }

  /// Decides the post-boot screen without adding delay: BiometricAuthScreen
  /// only when saved credentials exist AND the sensor can actually complete
  /// a prompt right now — otherwise SignInPage. If credentials exist but
  /// biometrics are no longer usable (fingerprints removed, sensor
  /// policy-disabled), the stale credentials are cleared first so the app
  /// self-heals instead of ever showing a prompt that can only fail.
  Future<Widget> _resolveAuthDestination() async {
    final hasCreds = await AuthService.hasBiometricCredentials();
    if (!hasCreds) return const SignInPage();

    final bioAvailable = await BiometricService.isAvailable();
    if (!bioAvailable) {
      await AuthService.clearBiometricCredentials();
      return const SignInPage();
    }

    return const BiometricAuthScreen();
  }

  Widget _buildBadge() => _PremiumLogo(scanAnim: _scanCtrl);

  Widget _buildWordmark() => const Text(
    'AEROGUARD',
    style: TextStyle(
      color: Colors.white,
      fontSize: 24,
      fontWeight: FontWeight.bold,
      letterSpacing: 9.0,
    ),
  );

  Widget _buildSubtitle() => const Text(
    'ZERO TRUST NETWORK ACCESS',
    style: TextStyle(
      color: Color(0xFF00C3FF),
      fontSize: 10,
      letterSpacing: 3.5,
      fontWeight: FontWeight.w500,
    ),
  );

  Widget _buildStatusBlock() => Column(
    children: [
      SizedBox(
        width: 180,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _progress),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          builder: (context, value, child) => LinearProgressIndicator(
            value: value,
            backgroundColor: Colors.white.withValues(alpha: 0.05),
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
  );

  // Badge pops with a scale+fade, the wordmark below it only fades (no
  // scale) so it settles in smoothly instead of bouncing in with the
  // badge. Same for both fromVideo and direct launches — see initState for
  // the one thing that does differ (when the status block below it starts).
  Widget _buildLogoBlock() {
    return AnimatedBuilder(
      animation: _logoCtrl,
      builder: (context, child) => Column(
        children: [
          Transform.scale(
            scale: _logoScale.value,
            child: Opacity(opacity: _logoOpacity.value, child: _buildBadge()),
          ),
          const SizedBox(height: 26),
          Opacity(opacity: _logoOpacity.value, child: _buildWordmark()),
          const SizedBox(height: 6),
          Opacity(opacity: _logoOpacity.value, child: _buildSubtitle()),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kHomeLoadBackgroundColor,
      // The gradient's lower stop is driven by _contentCtrl so the very
      // first frame (controller value 0, before its delayed .forward())
      // paints as pure kHomeLoadBackgroundColor — matching the intro
      // video's final frame exactly — then eases into the two-tone
      // gradient as content fades in.
      body: AnimatedBuilder(
        animation: _contentCtrl,
        builder: (context, child) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                kHomeLoadBackgroundColor,
                Color.lerp(
                  kHomeLoadBackgroundColor,
                  const Color(0xFF0A1628),
                  _contentCtrl.value,
                )!,
              ],
            ),
          ),
          child: child,
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Animated logo ──────────────────────────────────
              _buildLogoBlock(),

              const SizedBox(height: 72),

              // ── Progress + status ──────────────────────────────
              FadeTransition(
                opacity: _contentOpacity,
                child: SlideTransition(
                  position: _contentSlide,
                  child: _buildStatusBlock(),
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
