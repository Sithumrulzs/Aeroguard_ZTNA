import 'package:flutter/material.dart';

/// Soft white highlight along the top edge — the one shared "glass" cue
/// every translucent surface in the app reuses, so a light catches each
/// box the same way.
LinearGradient glassSheen() => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.white.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.0)],
    );

/// Translucent tinted fill for a small accent surface that doesn't warrant
/// its own backdrop blur (icon chips, pills, diagram nodes) — a two-stop
/// gradient so it still reads as glass rather than a flat wash. One place
/// to retune the tint recipe for every one of these.
LinearGradient glassTint(Color accent, {double alpha = 0.22}) => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [accent.withValues(alpha: alpha * 1.35), accent.withValues(alpha: alpha * 0.55)],
    );

/// The neutral card shell shared by every "plain" box on the dashboard —
/// same values the Network Topology card already uses. One flat, opaque
/// surface with a thin, unified border that wraps the whole rounded rect
/// cleanly; no per-accent tint, glow, or shadow, so boxes don't each carry
/// their own colored halo.
const Color neutralCardBg = Color(0xFF0D1421);
const Color neutralCardBorder = Color(0x26FFFFFF);

/// A premium colored surface built by blending a semi-transparent accent
/// wash into the neutral dark base — reads as a solid, rich color rather
/// than a flat single hex or a faint tint, without needing an opaque
/// gradient or a backdrop blur.
LinearGradient _blendedFill(Color accent, double alpha) => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(accent.withValues(alpha: alpha), neutralCardBg),
        Color.alphaBlend(accent.withValues(alpha: alpha * 0.55), neutralCardBg),
      ],
    );

class NeutralPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// When set, the fill becomes this color blended semi-transparently into
  /// the neutral base instead of the flat neutral fill — a premium colored
  /// surface rather than a plain dark box. The border stays mostly neutral
  /// (just a soft hint of the accent mixed in), so it never reads as its
  /// own distinct colored ring.
  final Color? accent;
  final double tintAlpha;

  const NeutralPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 16,
    this.accent,
    this.tintAlpha = 0.22,
  });

  @override
  Widget build(BuildContext context) {
    final tintedAccent = accent;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tintedAccent == null ? neutralCardBg : null,
        gradient: tintedAccent == null ? null : _blendedFill(tintedAccent, tintAlpha),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: tintedAccent == null
              ? neutralCardBorder
              : Color.alphaBlend(tintedAccent.withValues(alpha: 0.30), neutralCardBorder),
          width: 1.2,
        ),
      ),
      child: child,
    );
  }
}
