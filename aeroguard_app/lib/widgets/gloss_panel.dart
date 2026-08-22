import 'package:flutter/material.dart';
import '../config/theme.dart';

/// Light pastel wash for a small accent surface (icon chips, status badges)
/// — a two-stop gradient tuned for a white backdrop, not the deeper glow
/// this used to produce for a dark one. Same call signature as before, so
/// every existing `gradient: glassTint(accent)` call site needed zero
/// changes for the light-theme pass.
LinearGradient glassTint(Color accent, {double alpha = 0.16}) => LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [accent.withValues(alpha: alpha * 1.3), accent.withValues(alpha: alpha * 0.7)],
    );

/// The white card shell shared by every "plain" box on the dashboard — a
/// soft, colored-tinted shadow instead of a hard black one or a glowing
/// border, matching the rest of the blue/white theme (see AppColors).
class NeutralPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// When set, adds a thin colored accent bar down the left edge instead
  /// of tinting the whole card — status cards (gateway health, etc.) stay
  /// identifiable at a glance without a full-card color wash.
  final Color? accent;
  final double tintAlpha;

  /// When true (and [accent] is set), the whole card background washes
  /// transparent with [accent] instead of just getting a left-edge bar —
  /// for status cards where the entire box should read as "red = offline,
  /// green = online" at a glance, not just a thin stripe.
  final bool fillTint;

  const NeutralPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 16,
    this.accent,
    this.tintAlpha = 0.22,
    this.fillTint = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    final accent = this.accent;

    if (fillTint && accent != null) {
      return Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: content,
      );
    }

    return Container(
      clipBehavior: accent == null ? Clip.none : Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.border),
        boxShadow: AppColors.softShadow(tint: accent, opacity: 0.08),
      ),
      // Stack (not Row+stretch) for the accent bar — sizes itself from
      // `content`'s own intrinsic height, so it works in unbounded-height
      // contexts (e.g. a Column inside a scroll view) instead of throwing
      // "BoxConstraints forces an infinite height" the way stretch-aligned
      // Row children do when nothing upstream constrains the height.
      child: accent == null
          ? content
          : Stack(
              children: [
                content,
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 4, color: accent),
                ),
              ],
            ),
    );
  }
}
