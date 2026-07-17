import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/enclave_service.dart';
import '../config/transitions.dart';
import 'admin_dashboard.dart';
import 'sign_in_page.dart';

enum _AuthStatus { idle, scanning, success, failed, unavailable, loggingIn }

class BiometricAuthScreen extends StatefulWidget {
  const BiometricAuthScreen({super.key});

  @override
  State<BiometricAuthScreen> createState() => _BiometricAuthScreenState();
}

class _BiometricAuthScreenState extends State<BiometricAuthScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late AnimationController _glowCtrl;
  late Animation<double>   _pulseScale;
  late Animation<double>   _pulseOpacity;

  _AuthStatus _status       = _AuthStatus.idle;
  bool        _hasSavedCreds = false;
  String      _savedUsername = '';
  // Overrides the generic _AuthStatus.failed label with a specific reason
  // (e.g. locked out, unrecognised) from BiometricService.describeResult().
  String?     _statusDetail;

  bool _autoTriggerScheduled = false;
  Animation<double>? _routeAnimation;
  void Function(AnimationStatus)? _routeAnimationListener;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
        duration: const Duration(milliseconds: 1800), vsync: this)
      ..repeat(reverse: true);
    _glowCtrl = AnimationController(
        duration: const Duration(milliseconds: 1100), vsync: this)
      ..repeat(reverse: true);

    _pulseScale   = Tween<double>(begin: 0.94, end: 1.06).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _pulseOpacity = Tween<double>(begin: 0.3, end: 0.85).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Auto-trigger scheduling moved to didChangeDependencies — see there
    // for why a fixed delay isn't used.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_autoTriggerScheduled) return;
    _autoTriggerScheduled = true;

    // Android's BiometricPrompt is documented as unreliable if shown while
    // the hosting route is still mid-transition — this screen is reached
    // via bootToAuthRoute, whose transition takes 950ms, but the previous
    // fixed 600ms delay fired 350ms before that animation even finished.
    // That's exactly a "sometimes works, sometimes doesn't" bug: whether
    // the transition happened to already be done by 600ms depended on
    // device speed. Wait for the actual transition to complete instead of
    // guessing a number tied to another file's constant.
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _scheduleAutoTrigger();
      return;
    }
    _routeAnimation = animation;
    _routeAnimationListener = (status) {
      if (status == AnimationStatus.completed) {
        _routeAnimation?.removeStatusListener(_routeAnimationListener!);
        _scheduleAutoTrigger();
      }
    };
    animation.addStatusListener(_routeAnimationListener!);
  }

  void _scheduleAutoTrigger() {
    // Small buffer past the transition's own completion — some devices
    // still need a moment to settle native window focus even after
    // Flutter's animation reports done, before BiometricPrompt can
    // reliably attach.
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _checkAndTrigger();
    });
  }

  @override
  void dispose() {
    if (_routeAnimation != null && _routeAnimationListener != null) {
      _routeAnimation!.removeStatusListener(_routeAnimationListener!);
    }
    _pulseCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  // ── Init: check saved credentials then decide what to do ─────────────────
  Future<void> _checkAndTrigger() async {
    if (!mounted) return;

    final creds = await AuthService.getBiometricCredentials();
    final hasCreds = creds != null;

    if (mounted) setState(() => _hasSavedCreds = hasCreds);

    if (!hasCreds) return; // no saved creds — show manual login button only

    // Credentials saved — check hardware then trigger biometric prompt
    if (mounted) setState(() => _savedUsername = creds['username']!);

    final available = await BiometricService.isAvailable();
    if (!mounted) return;

    if (!available) {
      setState(() => _status = _AuthStatus.unavailable);
      return;
    }

    await _triggerBiometric();
  }

  // ── Biometric prompt ──────────────────────────────────────────────────────
  Future<void> _triggerBiometric() async {
    if (!mounted) return;
    setState(() {
      _status = _AuthStatus.scanning;
      _statusDetail = null;
    });

    final result = await BiometricService.authenticate(
      reason: 'Verify your identity',
    );
    if (!mounted) return;

    if (result == BiometricAuthResult.success) {
      await _autoLogin();
      return;
    }

    if (result == BiometricAuthResult.notEnrolled ||
        result == BiometricAuthResult.notAvailable) {
      // This device/state can never satisfy a biometric prompt — don't
      // strand the user on a screen that cannot work.
      await AuthService.clearBiometricCredentials();
      _goToManualLogin();
      return;
    }

    // Covers failure, error, lockedOut, and permanentlyLockedOut — stay on
    // screen with the specific reason; the password route is always there.
    setState(() {
      _status = _AuthStatus.failed;
      _statusDetail = BiometricService.describeResult(result);
    });
  }

  // ── Auto-login with stored credentials ───────────────────────────────────
  Future<void> _autoLogin() async {
    if (!mounted) return;
    setState(() => _status = _AuthStatus.loggingIn);

    final creds = await AuthService.getBiometricCredentials();
    if (creds == null) {
      _goToManualLogin();
      return;
    }

    final response = await AuthService.login(
      creds['username']!,
      creds['password']!,
    );
    if (!mounted) return;

    if (response.success) {
      await EnclaveService.initializeDevice(response.username ?? creds['username']!);
      setState(() => _status = _AuthStatus.success);
      await Future.delayed(const Duration(milliseconds: 700));
      if (mounted) {
        Navigator.pushReplacement(context, premiumRoute(const AdminDashboard()));
      }
    } else {
      // Stored creds rejected by server (e.g. password changed elsewhere) —
      // clear them and explain before falling back to manual login.
      await AuthService.clearBiometricCredentials();
      if (!mounted) return;
      await _showMessageDialog(
        'Your saved sign-in is no longer valid. Please sign in with your password.',
      );
      if (mounted) _goToManualLogin();
    }
  }

  void _goToManualLogin() {
    if (!mounted || _status == _AuthStatus.success) return;
    Navigator.pushReplacement(context, slideLeftRoute(const SignInPage()));
  }

  Future<void> _showMessageDialog(String message) {
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1421),
        title: const Text('Sign-In Required', style: TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Color(0xFFC0C7D4))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: Color(0xFF00C3FF))),
          ),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  Color get _color => switch (_status) {
        _AuthStatus.success   => const Color(0xFF10B981),
        _AuthStatus.failed    => const Color(0xFFEF4444),
        _AuthStatus.unavailable => const Color(0xFF475569),
        _AuthStatus.loggingIn => const Color(0xFF10B981),
        _                     => const Color(0xFF00C3FF),
      };

  String get _statusLabel => switch (_status) {
        _AuthStatus.idle        => _hasSavedCreds
                                    ? 'Touch sensor to unlock'
                                    : 'Sign in to get started',
        _AuthStatus.scanning    => 'Scanning biometric...',
        _AuthStatus.loggingIn   => 'Authenticating...',
        _AuthStatus.success     => 'Access granted',
        _AuthStatus.failed      => _statusDetail ?? 'Biometric failed — tap to retry',
        _AuthStatus.unavailable => 'Biometric unavailable',
      };

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;

    final badgeOuter  = h * 0.185;
    final badgeMiddle = h * 0.142;
    final badgeInner  = h * 0.105;
    final iconSize    = h * 0.058;

    final bool canRetry  = _status == _AuthStatus.failed;
    final bool isWorking = _status == _AuthStatus.scanning ||
                           _status == _AuthStatus.loggingIn ||
                           _status == _AuthStatus.success;

    return Scaffold(
      backgroundColor: const Color(0xFF050810),
      body: SizedBox.expand(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF050810), Color(0xFF0A1628)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                // ── Brand mark ───────────────────────────────────────────
                Padding(
                  padding: EdgeInsets.only(top: h * 0.034),
                  child: Text(
                    'AEROGUARD',
                    style: TextStyle(
                      color: const Color(0xFF475569).withValues(alpha: 0.5),
                      fontSize: h * 0.013,
                      letterSpacing: 4.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

                // Saved-user chip
                if (_hasSavedCreds && _savedUsername.isNotEmpty) ...[
                  SizedBox(height: h * 0.012),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C3FF).withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF00C3FF).withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      _savedUsername,
                      style: TextStyle(
                        color: const Color(0xFF00C3FF).withValues(alpha: 0.8),
                        fontSize: h * 0.013,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],

                const Spacer(flex: 7),

                // ── Fingerprint badge ─────────────────────────────────────
                GestureDetector(
                  onTap: canRetry ? _triggerBiometric : null,
                  child: _FingerprintBadge(
                    color:        _color,
                    status:       _status,
                    pulseScale:   _pulseScale,
                    pulseOpacity: _pulseOpacity,
                    glowAnim:     _glowCtrl,
                    outerSize:    badgeOuter,
                    middleSize:   badgeMiddle,
                    innerSize:    badgeInner,
                    iconSize:     iconSize,
                  ),
                ),

                SizedBox(height: h * 0.034),

                // ── Status label ──────────────────────────────────────────
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: Text(
                    _statusLabel,
                    key: ValueKey(_status),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _color.withValues(alpha: 0.75),
                      fontSize: h * 0.016,
                      letterSpacing: 0.3,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),

                // ── Retry chip (failure only) ─────────────────────────────
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  child: canRetry
                      ? Padding(
                          padding: EdgeInsets.only(top: h * 0.018),
                          child: GestureDetector(
                            onTap: _triggerBiometric,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                  color: const Color(0xFFEF4444)
                                      .withValues(alpha: 0.4),
                                ),
                                color: const Color(0xFFEF4444)
                                    .withValues(alpha: 0.06),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.refresh,
                                      color: Color(0xFFEF4444), size: 14),
                                  const SizedBox(width: 8),
                                  Text(
                                    'TRY AGAIN',
                                    style: TextStyle(
                                      color: const Color(0xFFEF4444),
                                      fontSize: h * 0.013,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),

                const Spacer(flex: 2),

                // ── Manual login button ───────────────────────────────────
                Padding(
                  padding: EdgeInsets.only(bottom: h * 0.05),
                  child: GestureDetector(
                    onTap: isWorking ? null : _goToManualLogin,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: isWorking ? 0.3 : 1.0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 22, vertical: 11),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: const Color(0xFF475569)
                                .withValues(alpha: 0.35),
                          ),
                          color: const Color(0xFF475569).withValues(alpha: 0.05),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline,
                              size: h * 0.017,
                              color: const Color(0xFF475569),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'SIGN IN MANUALLY',
                              style: TextStyle(
                                color: const Color(0xFF475569),
                                fontSize: h * 0.013,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Fingerprint badge ─────────────────────────────────────────────────────────

class _FingerprintBadge extends StatelessWidget {
  final Color color;
  final _AuthStatus status;
  final Animation<double> pulseScale;
  final Animation<double> pulseOpacity;
  final AnimationController glowAnim;
  final double outerSize;
  final double middleSize;
  final double innerSize;
  final double iconSize;

  const _FingerprintBadge({
    required this.color,
    required this.status,
    required this.pulseScale,
    required this.pulseOpacity,
    required this.glowAnim,
    required this.outerSize,
    required this.middleSize,
    required this.innerSize,
    required this.iconSize,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: outerSize,
      width:  outerSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: pulseScale,
            builder: (context, _) => Transform.scale(
              scale: pulseScale.value,
              child: Container(
                height: outerSize * 0.95,
                width:  outerSize * 0.95,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: pulseOpacity.value * 0.18),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: glowAnim,
            builder: (context, _) => Container(
              height: middleSize,
              width:  middleSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: color.withValues(alpha: 0.12 + glowAnim.value * 0.16),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.04 + glowAnim.value * 0.1),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
          Container(
            height: innerSize,
            width:  innerSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.06),
              border: Border.all(
                color: color.withValues(alpha: 0.45),
                width: 1.5,
              ),
            ),
          ),
          AnimatedBuilder(
            animation: pulseOpacity,
            builder: (context, _) => Opacity(
              opacity: 0.55 + pulseOpacity.value * 0.45,
              child: Icon(
                status == _AuthStatus.success || status == _AuthStatus.loggingIn
                    ? Icons.check_circle_outline
                    : Icons.fingerprint,
                size:  iconSize,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
