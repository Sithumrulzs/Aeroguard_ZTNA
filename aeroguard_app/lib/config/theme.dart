import 'package:flutter/material.dart';
import '../services/theme_controller.dart';

/// Shared blue/white (and now blue/near-black) brand palette. Every field
/// is a *getter*, not a const, so the same `AppColors.inkPrimary` call
/// site used throughout the app transparently resolves to the light or
/// dark value depending on ThemeController.instance.isDark — screens
/// never branch on theme themselves. This is why call sites that used to
/// read `const TextStyle(color: AppColors.inkPrimary)` had to drop the
/// `const`: a getter can never be a compile-time constant, even though it
/// reads like one.
class AppColors {
  AppColors._();

  static bool get _dark => ThemeController.instance.isDark.value;

  // Primary blue — same family as the logo mark itself, not a new,
  // unrelated brand color. Brighter in dark mode (pops against near-black)
  // than in light mode (needs to stay legible/AA on white), same hue family
  // throughout — "our branding colors" stays true in both themes.
  static Color get brandBlue => _dark ? const Color(0xFF5B93FF) : const Color(0xFF2F6FEE);
  static Color get brandBlueDark => _dark ? const Color(0xFF2F6FEE) : const Color(0xFF1B3FBD);
  static Color get brandBlueBright => _dark ? const Color(0xFF8FB4FF) : const Color(0xFF5B93FF);

  // The one dark surface in the light theme (hero/feature cards only); in
  // dark mode this is just the deepest background tone, used the same way
  // Material's dark scheme uses a near-black under its raised surfaces.
  static Color get navy => const Color(0xFF0B1220);

  // Text
  static Color get inkPrimary => _dark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
  static Color get inkSecondary => _dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  static Color get inkFaint => _dark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);

  // Surfaces — in light mode `surface` (white cards) sits *above*
  // `surfaceMuted` (page bg); in dark mode the same relationship holds
  // (cards a shade lighter than the page), matching how depth reads in
  // each theme rather than just inverting one variable.
  static Color get surface => _dark ? const Color(0xFF141B2E) : Colors.white;
  static Color get surfaceMuted => _dark ? const Color(0xFF0B1220) : const Color(0xFFF3F6FB);
  static Color get border => _dark ? const Color(0xFF2A3350) : const Color(0xFFE2E8F0);

  // Status — lightened slightly in dark mode; the light-mode values read
  // fine on white but lose contrast against near-black at the same
  // saturation.
  static Color get success => _dark ? const Color(0xFF34D399) : const Color(0xFF10B981);
  static Color get danger => _dark ? const Color(0xFFF87171) : const Color(0xFFEF4444);
  static Color get amber => _dark ? const Color(0xFFFBBF24) : const Color(0xFFF59E0B);

  static LinearGradient get blueButtonGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandBlueBright, brandBlue],
  );

  /// Light mode: a soft colored shadow beneath the card (classic
  /// elevation-by-light-source cue). Dark mode: shadows read as nothing
  /// against near-black, so this switches to a faint all-around glow in
  /// the same tint instead — the dark-theme equivalent of "this card is
  /// raised."
  static List<BoxShadow> softShadow({Color? tint, double opacity = 0.10}) {
    final color = tint ?? brandBlue;
    if (_dark) {
      return [
        BoxShadow(
          color: color.withValues(alpha: opacity * 0.9),
          blurRadius: 20,
          spreadRadius: 0.5,
        ),
      ];
    }
    return [
      BoxShadow(
        color: color.withValues(alpha: opacity),
        blurRadius: 32,
        offset: const Offset(0, 14),
      ),
    ];
  }
}
