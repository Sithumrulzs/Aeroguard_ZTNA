import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/auth_service.dart';
import '../services/enclave_service.dart';
import 'home_load_page.dart';

// ── Handoff timing ──────────────────────────────────────────────────────
// The asset itself is trimmed and graded to end here: the turbine zooms in
// to fill the frame around 5.5-6.5s and a fade baked into the last ~0.5s
// of the file eases it to an exact, pixel-matched kHomeLoadBackgroundColor
// by 6.6s (the file's full length, which also carries its own synced
// engine-ambience audio bed) — no separate trailing static hold to cut
// around. This constant sits 100ms before that true end, purely as a
// safety margin against video_player's position/duration edge cases, not
// as a color-correction trim. At this position the screen cuts straight to
// HomeLoadPage with zero fade of our own, so its reveal lands in the very
// same instant. The transition accent itself is triggered separately, by
// HomeLoadPage, right as it mounts — see that screen's initState.
const int _videoCutoffMs = 6500;
// Tapping to skip *before* that position jumps from an arbitrary, likely
// colorful video frame rather than the matching dark ending — that jump
// still gets a quick color-matched fade first so it isn't a jarring pop.
// Not used for the cutoff above, which is already at the matching color.
const int _skipFadeMs = 300;
// How long the video itself takes to fade in from the (black) scaffold
// background once it starts playing, instead of snapping straight to
// fully visible.
const int _fadeInMs = 500;

/// Cold-start intro video — full-bleed, skippable, and purely cosmetic.
/// It must never delay reaching [HomeLoadPage], so every exit path
/// (completion, tap, or a slow/failed initialization) funnels through
/// [_goToHome].
class IntroVideoScreen extends StatefulWidget {
  const IntroVideoScreen({super.key});

  /// Enclave init kicked off from [initState] so the video's ~7s runtime
  /// doubles as loading time. HomeLoadPage's own boot sequence awaits this
  /// same future instead of starting a second, redundant initialization.
  static Future<void>? enclaveInitFuture;

  @override
  State<IntroVideoScreen> createState() => _IntroVideoScreenState();
}

class _IntroVideoScreenState extends State<IntroVideoScreen>
    with TickerProviderStateMixin {
  VideoPlayerController? _controller;
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeOpacity;
  late final AnimationController _fadeInCtrl;
  late final Animation<double> _fadeInOpacity;

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
    _fadeInCtrl = AnimationController(
      duration: const Duration(milliseconds: _fadeInMs),
      vsync: this,
    );
    _fadeInOpacity = CurvedAnimation(
      parent: _fadeInCtrl,
      curve: Curves.easeOut,
    );

    final controller = VideoPlayerController.asset(
      'assets/video/aeroguard_intro_noword.mp4',
    );
    _controller = controller;
    controller.addListener(_onVideoTick);

    controller
        .initialize()
        .then((_) {
          if (!mounted || _navigated) return;
          controller.play();
          _fadeInCtrl.forward();
          setState(() {});
        })
        .catchError((_) {
          // Decoder/asset failure — cosmetic layer, just move on.
          _goToHome();
        });

    // The video is cosmetic and must never block boot.
    Future.delayed(const Duration(milliseconds: 800), () {
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
      // Already at the matching dark ending — cut immediately, no fade, so
      // the reveal lands in the same instant the turbine goes dark.
      _handoffStarted = true;
      _goToHome();
    }
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
    if (controller.value.position >=
        const Duration(milliseconds: _videoCutoffMs)) {
      _handoffStarted = true;
      _goToHome();
    } else {
      // Skipping mid-video — this frame isn't near the background color,
      // so mask the jump with a quick fade first.
      _startHandoff();
    }
  }

  // Fades a color-matched overlay over the (still-playing) video before
  // handing off. Only used when skipping earlier than _videoCutoffMs,
  // where the current frame is an arbitrary color, not the matching dark
  // ending — the natural end-of-video handoff above cuts instantly instead.
  void _startHandoff() {
    if (_navigated || _handoffStarted) return;
    _handoffStarted = true;
    _fadeCtrl.forward().whenComplete(_goToHome);
  }

  void _goToHome() {
    if (_navigated || !mounted) return;
    _navigated = true;
    // A plain instant swap, not a route-level crossfade: by the time this
    // runs, the screen is already either the video's matching-color ending
    // or (for an early skip) the fully-opaque overlay — both pixel-
    // identical to HomeLoadPage's own background, so there's nothing left
    // to blend at the route level. Layering a second fade on top of
    // HomeLoadPage's own entrance (which starts animating the instant it
    // mounts) would just multiply the two together into a duller,
    // slower-reading reveal instead of one clean, decisive motion.
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const HomeLoadPage(fromVideo: true),
      ),
    );
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _fadeCtrl.dispose();
    _fadeInCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isReady = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: kHomeLoadBackgroundColor,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Fades in from the (black) scaffold background once playback
            // starts, instead of snapping straight to fully visible.
            isReady
                ? FadeTransition(
                    opacity: _fadeInOpacity,
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller.value.size.width,
                        height: controller.value.size.height,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
            // Color-perfect handoff overlay — fades in above the video so
            // the cut into HomeLoadPage shows zero visible color step.
            FadeTransition(
              opacity: _fadeOpacity,
              child: Container(color: kHomeLoadBackgroundColor),
            ),
          ],
        ),
      ),
    );
  }
}
