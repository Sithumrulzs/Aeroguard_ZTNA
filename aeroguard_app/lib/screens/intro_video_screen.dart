import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/enclave_service.dart';
import 'biometric_auth_screen.dart';
import 'sign_in_page.dart';
import 'vendor_dashboard.dart';

// Boot-screen background — the intro video is the only loading UI now, so
// this is just what shows before the first video frame and behind the
// handoff fade; no separate loading screen exists to keep it in sync with.
const Color kBootBackgroundColor = Color(0xFF050810);

// ── Handoff timing ──────────────────────────────────────────────────────
// shots.mp4 is exactly 5.0s, video-only (no audio bed), and does not fade
// to a matching dark ending; it settles on a plain white logo-reveal
// frame. So reaching this position is never a color-matched cut on its
// own: _onVideoTick always routes through the same fade overlay _onTap
// uses for an early skip (see _startHandoff), masking the white-to-dark
// jump either way. 100ms before the true 5000ms length, as a safety
// margin against video_player's position/duration edge cases.
const int _videoCutoffMs = 4900;
// Fade duration for the color-matched overlay — used both for an early
// tap-to-skip and for reaching _videoCutoffMs naturally, since neither
// case lands on a frame that already matches the next screen.
const int _skipFadeMs = 300;

/// Cold-start intro video — full-bleed, skippable, and the only loading
/// animation in the app now. It must never delay reaching the resolved
/// auth screen, so every exit path (completion, tap, or a slow/failed
/// initialization) funnels through [_goToHome], and destination
/// resolution itself starts immediately in [initState] rather than after
/// the video ends, so it's normally already done by the time the fade
/// finishes instead of adding a visible second wait.
class IntroVideoScreen extends StatefulWidget {
  const IntroVideoScreen({super.key});

  /// Enclave init kicked off from [initState] so the video's ~5s runtime
  /// doubles as loading time. Shared with [resolveDestination] callers
  /// that also need it initialized before landing on an authenticated
  /// screen.
  static Future<void>? enclaveInitFuture;

  /// Decides which screen to land on, with no visible loading step of its
  /// own: a still-valid vendor session skips straight back to
  /// [VendorDashboard]; otherwise [BiometricAuthScreen] when a sensor and
  /// saved credentials are both usable, else [SignInPage]. Public (and
  /// static, not tied to any instance) so [main.dart]'s hot-resume /
  /// reduce-motion path — which skips the video entirely — can reuse the
  /// exact same resolution instead of duplicating it.
  static Future<Widget> resolveDestination() async {
    final vendorSession = await AuthService.getVendorSession();
    if (vendorSession != null) {
      try {
        final expires = DateTime.parse(vendorSession['expiresAt']!);
        if (DateTime.now().toUtc().isBefore(expires.toUtc())) {
          return VendorDashboard(
            vendorName: vendorSession['vendorName']!,
            company: vendorSession['company']!,
            token: vendorSession['token']!,
            expiresAt: vendorSession['expiresAt']!,
          );
        }
      } catch (_) {}
      // Unparsable or expired — stale, drop it and fall through to admin flow.
      await AuthService.clearVendorSession();
    }

    final hasCreds = await AuthService.hasBiometricCredentials();
    if (!hasCreds) return const SignInPage();

    final bioAvailable = await BiometricService.isAvailable();
    if (!bioAvailable) {
      await AuthService.clearBiometricCredentials();
      return const SignInPage();
    }

    return const BiometricAuthScreen();
  }

  @override
  State<IntroVideoScreen> createState() => _IntroVideoScreenState();
}

class _IntroVideoScreenState extends State<IntroVideoScreen>
    with TickerProviderStateMixin {
  VideoPlayerController? _controller;
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeOpacity;

  // shots.mp4 has no audio bed of its own (see the file-level comment) — a
  // separate player just for a plane-flying sound bed, started alongside
  // the video and stopped whenever this screen exits, however it exits.
  // Purely a sound layer: never gates or times any of the existing
  // navigation/fade logic.
  final AudioPlayer _planeSoundPlayer = AudioPlayer();

  // Kicked off immediately, in parallel with the video and enclave init —
  // by the time anything actually navigates, this has normally already
  // resolved, so awaiting it later adds no visible delay.
  late final Future<Widget> _destinationFuture = IntroVideoScreen
      .resolveDestination();

  bool _navigated = false;
  bool _handoffStarted = false;

  @override
  void initState() {
    super.initState();

    IntroVideoScreen.enclaveInitFuture ??= AuthService.getUsername().then(
      (username) => EnclaveService.initializeDevice(username ?? 'admin'),
    );

    _fadeCtrl = AnimationController(
      duration: const Duration(milliseconds: _skipFadeMs),
      vsync: this,
    );
    _fadeOpacity = CurvedAnimation(
      parent: _fadeCtrl,
      curve: Curves.easeInOut,
    );

    final controller = VideoPlayerController.asset(
      'assets/video/shots.mp4',
    );
    _controller = controller;
    controller.addListener(_onVideoTick);

    controller
        .initialize()
        .then((_) {
          if (!mounted || _navigated) return;
          controller.play();
          unawaited(_planeSoundPlayer.play(AssetSource('audio/Plane_flying.mp3')));
          setState(() {});
        })
        .catchError((_) {
          // Decoder/asset failure — cosmetic layer, just move on.
          _goToHome();
        });

    // The video is cosmetic and must never block boot — but 800ms turned
    // out to be shorter than real hardware decoder cold-start (codec
    // allocation + surface negotiation routinely takes longer than that on
    // a physical device, confirmed live: ExoPlayer was Release()'d mid
    // codec setup, before rendering a single frame, every launch). 2.5s
    // gives real initialization a fair chance while still bounding the
    // worst case well under the video's own ~5s runtime.
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted || _navigated) return;
      if (!controller.value.isInitialized) _goToHome();
    });
  }

  void _onVideoTick() {
    final controller = _controller;
    if (controller == null || _navigated || _handoffStarted) return;
    final value = controller.value;
    if (!value.isInitialized) return;
    if (value.position >= const Duration(milliseconds: _videoCutoffMs)) {
      // shots.mp4 ends on a white logo-reveal frame, not the app's dark
      // theme — always mask the jump with the fade, same as an early skip.
      _startHandoff();
      return;
    }
    // Forces a repaint on every position update instead of relying solely
    // on the platform texture's own "new frame available" signal — on this
    // device/driver combo that signal wasn't reliably reaching the
    // compositor, confirmed live: the decoder ran correctly (position
    // presumably advancing) but the on-screen Texture stayed locked to the
    // first frame for 7+ seconds straight, well past the cutoff, with
    // disabling Impeller alone not fixing it. Cheap — just marks this
    // widget dirty, doesn't rebuild the video's own decode pipeline.
    if (mounted) setState(() {});
  }

  void _onTap() {
    if (_navigated || _handoffStarted) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      // No video frame on screen yet — the scaffold is already showing the
      // matching background color, so an instant cut is invisible anyway.
      _goToHome();
      return;
    }
    // No frame in this clip matches the next screen's background (it ends
    // on a plain white logo reveal) — every exit, early skip or reaching
    // _videoCutoffMs, masks the jump with the same fade.
    _startHandoff();
  }

  // Fades a color-matched overlay over the (still-playing) video before
  // handing off — used for every exit path once a frame is actually on
  // screen, since no point in shots.mp4 already matches the next screen's
  // background (see _onVideoTick / _onTap).
  void _startHandoff() {
    if (_navigated || _handoffStarted) return;
    _handoffStarted = true;
    _fadeCtrl.forward().whenComplete(_goToHome);
  }

  Future<void> _goToHome() async {
    if (_navigated || !mounted) return;
    _navigated = true;
    // Captured now, while this widget is definitely still active, and used
    // below instead of a second `Navigator.of(context)` call after the
    // await. `State.mounted` only tracks disposal, not deactivation — this
    // widget's element can go briefly inactive (still "mounted") during the
    // gap below, and calling `Navigator.of(context)` in that window throws
    // "Looking up a deactivated widget's ancestor is unsafe", which — since
    // the handoff fade has already gone fully opaque by the time this runs
    // — would strand the screen on a solid, seemingly-frozen frame instead
    // of completing the handoff. A `NavigatorState` captured beforehand
    // stays valid across that gap; only its own `mounted` needs checking.
    final navigator = Navigator.of(context);
    // Normally already resolved (kicked off in initState, well before any
    // exit path can fire) — this await is just claiming the result, not
    // adding a real wait.
    final destination = await _destinationFuture;
    if (!navigator.mounted) return;
    // A plain instant swap, not a route-level crossfade: by the time this
    // runs, the screen is already either the fully-opaque handoff overlay
    // (a frame was showing) or the untouched scaffold background (no frame
    // ever appeared — load failure, slow init, or a tap before ready) —
    // either way pixel-identical to kBootBackgroundColor, so there's
    // nothing left to blend at the route level. The destination screens
    // each run their own independent entrance animation from there.
    navigator.pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => destination,
      ),
    );
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _fadeCtrl.dispose();
    _planeSoundPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isReady = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: kBootBackgroundColor,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Snaps straight to visible once playback starts — no fade-in.
            isReady
                ? FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: controller.value.size.width,
                      height: controller.value.size.height,
                      child: VideoPlayer(controller),
                    ),
                  )
                : const SizedBox.shrink(),
            // Color-perfect handoff overlay — fades in above the video so
            // the cut into the resolved screen shows zero visible color step.
            FadeTransition(
              opacity: _fadeOpacity,
              child: Container(color: kBootBackgroundColor),
            ),
          ],
        ),
      ),
    );
  }
}
