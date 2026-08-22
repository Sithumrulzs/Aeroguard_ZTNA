import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/theme_controller.dart';

/// AeroGuard-branded light/dark toggle. A standard sliding thumb (sun ⇄
/// crescent moon — the only place either glyph appears, so the track never
/// duplicates it) rides on top of a little sky that morphs from day to
/// night. The track itself just shows that sky doing its thing — realistic
/// puffy clouds by day, a starfield by night — with the AeroGuard jet
/// silhouette crossfading in on whichever side is now showing rather than
/// sliding across (a full-width slide read as the plane "jumping" instead
/// of flying), each anchored near where the thumb has just uncovered it.
class ThemeToggleSwitch extends StatefulWidget {
  const ThemeToggleSwitch({super.key, this.scale = 1.0});

  /// Multiplier over the base 108x46 track — bump this up wherever the
  /// toggle needs to read clearly as its own control rather than a small
  /// accent.
  final double scale;

  @override
  State<ThemeToggleSwitch> createState() => _ThemeToggleSwitchState();
}

class _ThemeToggleSwitchState extends State<ThemeToggleSwitch>
    with SingleTickerProviderStateMixin {
  static const _planeAsset = 'assets/images/Aeroguard_Plane_Black.svg';
  // Source SVG viewBox is 350x220 — keep the silhouette undistorted at any scale.
  static const _planeAspect = 220 / 350;
  static const _dayPlaneColor = Color(0xFF0F1626);
  static const _nightPlaneColor = Color(0xFF4A5A82);

  late final AnimationController _ctrl;
  late final Animation<double> _eased;

  double get _w => 108 * widget.scale;
  double get _h => 46 * widget.scale;
  double get _thumbMargin => 3 * widget.scale;
  double get _thumbD => _h - _thumbMargin * 2;
  double get _planeW => 46 * widget.scale;
  double get _planeH => _planeW * _planeAspect;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: ThemeController.instance.isDark.value ? 1 : 0,
    );
    // Ease-in/ease-out rather than the controller's raw linear ticks — this
    // is what makes the crossfade/slide feel smooth instead of mechanical,
    // since every position and opacity below reads off `_eased.value`, not
    // `_ctrl.value` directly.
    _eased = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final goingDark = !ThemeController.instance.isDark.value;
    if (goingDark) {
      await _ctrl.forward();
    } else {
      await _ctrl.reverse();
    }
    if (!mounted) return;
    // The controller/scene animation is purely local; the actual app-wide
    // switch (and its persistence) happens here, once the motion has
    // finished playing rather than instantly at tap-down.
    await ThemeController.instance.set(goingDark);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Toggle dark mode',
      toggled: ThemeController.instance.isDark.value,
      child: GestureDetector(
        onTap: _toggle,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final s = widget.scale;
            final t = _eased.value; // eased 0 = day/light, 1 = night/dark
            final skyColors = [
              Color.lerp(const Color(0xFF57A6E8), const Color(0xFF060A16), t)!,
              Color.lerp(const Color(0xFF8FCBF2), const Color(0xFF141E38), t)!,
              Color.lerp(const Color(0xFFE9F6FF), const Color(0xFF223058), t)!,
            ];

            // Thumb slides left → right as t: 0 → 1.
            final thumbTravel = _w - _thumbD - _thumbMargin * 2;
            final thumbX = _thumbMargin + thumbTravel * t;

            // Two near-static planes, each anchored on the side its mode
            // reveals, crossfading rather than travelling — no more
            // "jump" across the whole track.
            final dayOpacity = (1 - t * 1.8).clamp(0.0, 1.0);
            final nightOpacity = ((t - 0.45) * 1.8).clamp(0.0, 1.0);
            final bob = math.sin(t * math.pi * 2) * (2.0 * s);
            final planeCy = _h * 0.50 + bob;
            final tilt = -0.04 + 0.03 * math.sin(t * math.pi * 2);
            final dayPlaneCx = _w * 0.70;
            final nightPlaneCx = _w * 0.30;

            final cloudOpacity = (1 - t).clamp(0.0, 1.0);
            final starOpacity = t.clamp(0.0, 1.0);
            final sunOpacity = (1 - t * 1.5).clamp(0.0, 1.0);
            final moonOpacity = ((t - 0.42) * 1.7).clamp(0.0, 1.0);

            return SizedBox(
              width: _w,
              height: _h,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: _w,
                    height: _h,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_h / 2),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.0, 0.55, 1.0],
                        colors: skyColors,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(_h / 2),
                      child: SizedBox(
                        width: _w,
                        height: _h,
                        child: Stack(
                          children: [
                            // A faint inner vignette along the top edge —
                            // just enough to keep the sky from looking flat.
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.center,
                                    colors: [Colors.white.withValues(alpha: 0.10), Colors.transparent],
                                  ),
                                ),
                              ),
                            ),
                            // Night sky — starfield, varied sizes for depth.
                            _star(_w * 0.10, _h * 0.20, 2.4 * s, 0.9, starOpacity),
                            _star(_w * 0.20, _h * 0.62, 1.6 * s, 0.5, starOpacity),
                            _star(_w * 0.88, _h * 0.24, 2.0 * s, 0.75, starOpacity),
                            _star(_w * 0.62, _h * 0.14, 1.4 * s, 0.55, starOpacity),
                            _star(_w * 0.38, _h * 0.80, 1.4 * s, 0.45, starOpacity),
                            _star(_w * 0.48, _h * 0.30, 1.2 * s, 0.5, starOpacity),
                            _star(_w * 0.76, _h * 0.68, 1.8 * s, 0.6, starOpacity),
                            // Distant lights along the horizon — dark only.
                            for (final fx in [0.58, 0.68, 0.80, 0.90])
                              Positioned(
                                left: _w * fx,
                                bottom: _h * 0.10,
                                child: Opacity(
                                  opacity: moonOpacity * 0.8,
                                  child: Container(
                                    width: 2.4 * s,
                                    height: 2.4 * s,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFFFFC24B),
                                    ),
                                  ),
                                ),
                              ),
                            // Sunny sky — realistic puffy clouds.
                            Positioned(
                              left: _w * 0.54,
                              bottom: _h * 0.10,
                              child: Opacity(
                                opacity: cloudOpacity * 0.95,
                                child: _cloud(_w * 0.24, _h * 0.17, s),
                              ),
                            ),
                            Positioned(
                              left: _w * 0.80,
                              bottom: _h * 0.22,
                              child: Opacity(
                                opacity: cloudOpacity * 0.75,
                                child: _cloud(_w * 0.15, _h * 0.11, s),
                              ),
                            ),
                            Positioned(
                              left: _w * 0.60,
                              bottom: _h * 0.34,
                              child: Opacity(
                                opacity: cloudOpacity * 0.55,
                                child: _cloud(_w * 0.12, _h * 0.09, s),
                              ),
                            ),
                            // Day plane — fades out as night takes over.
                            _planeGroup(
                              cx: dayPlaneCx,
                              cy: planeCy,
                              tilt: tilt,
                              opacity: dayOpacity,
                              color: _dayPlaneColor,
                              s: s,
                            ),
                            // Night plane — fades in on the newly revealed side.
                            _planeGroup(
                              cx: nightPlaneCx,
                              cy: planeCy,
                              tilt: tilt,
                              opacity: nightOpacity,
                              color: _nightPlaneColor,
                              s: s,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── Thumb ──────────────────────────────────────────────
                  // The sun/moon glyph lives here and only here — the track
                  // never shows a second one.
                  Positioned(
                    left: thumbX,
                    top: _thumbMargin,
                    child: Container(
                      width: _thumbD,
                      height: _thumbD,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          center: const Alignment(-0.3, -0.4),
                          radius: 1.0,
                          colors: [
                            Color.lerp(Colors.white, const Color(0xFFF5F8FF), t)!,
                            Color.lerp(const Color(0xFFE7ECF5), const Color(0xFF17223D), t)!,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.28),
                            blurRadius: 6 * s,
                            offset: Offset(0, 2 * s),
                          ),
                        ],
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Glossy highlight.
                          Positioned(
                            left: _thumbD * 0.14,
                            top: _thumbD * 0.12,
                            child: Container(
                              width: _thumbD * 0.42,
                              height: _thumbD * 0.30,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(_thumbD * 0.2),
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white.withValues(alpha: 0.55),
                                    Colors.white.withValues(alpha: 0.0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Opacity(
                            opacity: sunOpacity,
                            child: Icon(Icons.wb_sunny_rounded, color: const Color(0xFFF5A623), size: _thumbD * 0.5),
                          ),
                          Opacity(
                            opacity: moonOpacity,
                            child: Icon(Icons.nightlight_round, color: const Color(0xFFEAF1FF), size: _thumbD * 0.46),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _planeGroup({
    required double cx,
    required double cy,
    required double tilt,
    required double opacity,
    required Color color,
    required double s,
  }) {
    if (opacity <= 0.0) return const SizedBox.shrink();
    return Positioned(
      left: cx - _planeW / 2,
      top: cy - _planeH / 2,
      width: _planeW,
      height: _planeH,
      child: Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: tilt,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Cheap offset shadow copy — no live blur filter.
              Positioned(
                left: 1.2 * s,
                top: _planeH * 0.10,
                child: Opacity(
                  opacity: 0.28,
                  child: SvgPicture.asset(
                    _planeAsset,
                    width: _planeW,
                    height: _planeH,
                    colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
                  ),
                ),
              ),
              SvgPicture.asset(
                _planeAsset,
                width: _planeW,
                height: _planeH,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _star(double left, double top, double size, double baseOpacity, double t) {
    return Positioned(
      left: left,
      top: top,
      child: Opacity(
        opacity: t * baseOpacity,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
        ),
      ),
    );
  }

  // A realistic-ish cumulus puff: several overlapping soft-shadowed circles
  // plus a flat base, instead of a single flat capsule.
  Widget _cloud(double w, double h, double s) {
    Widget puff(double left, double bottom, double d) {
      return Positioned(
        left: left,
        bottom: bottom,
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.94),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 1.5 * s, offset: Offset(0, 0.8 * s)),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      width: w,
      height: h * 1.3,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: w * 0.10,
            bottom: 0,
            child: Container(
              width: w * 0.82,
              height: h * 0.55,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(h),
              ),
            ),
          ),
          puff(0, h * 0.18, h * 0.85),
          puff(w * 0.26, h * 0.42, h * 1.05),
          puff(w * 0.56, h * 0.24, h * 0.90),
          puff(w * 0.34, h * 0.02, h * 0.62),
        ],
      ),
    );
  }
}
