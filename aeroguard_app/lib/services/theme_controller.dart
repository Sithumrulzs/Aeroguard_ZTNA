import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Global reactive light/dark switch — a plain ValueNotifier rather than
/// Provider/Riverpod, matching how the rest of this app already manages
/// state (Timer + setState per screen, no DI layer to plug into). Screens
/// don't listen to this directly: main.dart remounts the entire tree on
/// change (see AeroGuardApp), so every AppColors.* getter just re-resolves
/// naturally on the next build instead of every screen needing its own
/// listener.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _key = 'aeroguard_dark_mode';
  static final _vault = const FlutterSecureStorage();

  final ValueNotifier<bool> isDark = ValueNotifier<bool>(false);
  bool _loaded = false;

  /// Reads the persisted preference once at cold start. Defaults to light
  /// (this app's primary designed theme) until/unless a user has actually
  /// toggled dark mode before.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final stored = await _vault.read(key: _key);
      if (stored != null) isDark.value = stored == 'true';
    } catch (_) {
      // Secure storage unavailable (rare) — stay on the light default
      // rather than block boot on a purely cosmetic preference.
    }
  }

  Future<void> toggle() => set(!isDark.value);

  Future<void> set(bool dark) async {
    isDark.value = dark;
    try {
      await _vault.write(key: _key, value: dark ? 'true' : 'false');
    } catch (_) {}
  }
}
