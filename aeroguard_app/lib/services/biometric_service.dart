import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Detailed result returned by [BiometricService.authenticate].
/// Gives the UI enough information to surface actionable copy without the
/// service layer knowing anything about widgets.
enum BiometricAuthResult {
  success,
  failure,               // user cancelled or did not match
  notEnrolled,           // hardware present, but no biometrics registered
  notAvailable,          // no sensor, or disabled by device policy
  lockedOut,             // too many failures — temporary lockout
  permanentlyLockedOut,  // permanent lockout — must unlock with device PIN
  passcodeNotSet,        // no device PIN configured (OS prerequisite)
  error,                 // unexpected platform exception
}

class BiometricService {
  static final LocalAuthentication _auth = LocalAuthentication();

  // ── Capability queries ────────────────────────────────────────────────────

  /// Returns true only when the device has a sensor AND biometrics are enrolled.
  /// Safe to call on every app start — all exceptions are swallowed.
  static Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      final List<BiometricType> enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } on PlatformException catch (e) {
      debugPrint('[-] BiometricService.isAvailable [${e.code}]: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[-] BiometricService.isAvailable: $e');
      return false;
    }
  }

  /// Returns the types of biometrics currently enrolled on the device
  /// (fingerprint, face, iris). Returns empty list on any error.
  static Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return [];
    }
  }

  // ── Core authentication ───────────────────────────────────────────────────

  /// Shows the OS-level biometric prompt and returns a [BiometricAuthResult].
  ///
  /// This is the canonical authentication entry-point. Every PlatformException
  /// code emitted by local_auth on both Android and iOS is explicitly mapped so
  /// the caller never sees an unhandled exception crash.
  static Future<BiometricAuthResult> authenticate({
    required String reason,
  }) async {
    try {
      // Pre-flight: hardware capability
      final bool hasHardware = await _auth.isDeviceSupported();
      final bool canCheck    = await _auth.canCheckBiometrics;
      if (!hasHardware && !canCheck) {
        debugPrint('[-] Biometric: hardware absent or policy-disabled.');
        return BiometricAuthResult.notAvailable;
      }

      // Pre-flight: enrollment state
      final List<BiometricType> enrolled = await _auth.getAvailableBiometrics();
      if (enrolled.isEmpty) {
        debugPrint('[-] Biometric: no biometrics enrolled — enroll in OS settings.');
        return BiometricAuthResult.notEnrolled;
      }

      final bool didAuth = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly:   true,
          // stickyAuth keeps the system dialog alive when the user briefly
          // switches apps, preventing spurious "cancelled" results.
          stickyAuth:      true,
          useErrorDialogs: true,
        ),
      );

      if (didAuth) {
        debugPrint('[+] Biometric: authentication confirmed.');
        return BiometricAuthResult.success;
      } else {
        debugPrint('[!] Biometric: cancelled or did not match.');
        return BiometricAuthResult.failure;
      }

    } on PlatformException catch (e) {
      // Map every known local_auth / platform error code to a typed result.
      // Android codes come from BiometricPrompt constants; iOS codes are
      // mapped by the local_auth plugin from LAError enums.
      debugPrint('[-] Biometric PlatformException [${e.code}]: ${e.message}');

      switch (e.code) {
        // ── Not enrolled ─────────────────────────────────────────────────
        case 'NotEnrolled':
        case 'notEnrolled':
        case 'biometric_not_enrolled':
          return BiometricAuthResult.notEnrolled;

        // ── Temporary lockout (too many failed attempts) ───────────────
        case 'LockedOut':
        case 'lockedOut':
        case 'biometric_error_lockout':
          return BiometricAuthResult.lockedOut;

        // ── Permanent lockout (requires device PIN to reset) ──────────
        case 'PermanentlyLockedOut':
        case 'permanentlyLockedOut':
        case 'biometric_error_lockout_permanent':
          return BiometricAuthResult.permanentlyLockedOut;

        // ── Hardware unavailable or policy-disabled ───────────────────
        case 'NotAvailable':
        case 'notAvailable':
        case 'biometricOnlyNotSupported':
        case 'biometric_error_hw_unavailable':
        case 'biometric_error_no_hardware':
          return BiometricAuthResult.notAvailable;

        // ── Device has no PIN set (prerequisite for biometrics) ───────
        case 'PasscodeNotSet':
        case 'passcodeNotSet':
        case 'biometric_error_no_device_credential':
          return BiometricAuthResult.passcodeNotSet;

        default:
          return BiometricAuthResult.error;
      }

    } catch (e) {
      debugPrint('[-] Biometric: unexpected error — $e');
      return BiometricAuthResult.error;
    }
  }

  /// Convenience wrapper for call-sites that only need a boolean result.
  /// Used by the admin login flow after biometric credentials are saved.
  static Future<bool> authenticateAdmin() async {
    final result = await authenticate(
      reason: 'AeroGuard ZTNA: Verify your identity to access the datacenter gateway.',
    );
    return result == BiometricAuthResult.success;
  }

  /// Human-readable summary of a [BiometricAuthResult] for snackbars / dialogs.
  static String describeResult(BiometricAuthResult result) {
    return switch (result) {
      BiometricAuthResult.success             => 'Identity verified.',
      BiometricAuthResult.failure             => 'Biometric not recognised. Try again.',
      BiometricAuthResult.notEnrolled         => 'No biometrics enrolled. Register a fingerprint or Face ID in device Settings.',
      BiometricAuthResult.notAvailable        => 'No biometric sensor detected on this device.',
      BiometricAuthResult.lockedOut           => 'Biometric locked out after too many attempts. Wait and try again.',
      BiometricAuthResult.permanentlyLockedOut => 'Biometric permanently locked. Unlock with your device PIN first.',
      BiometricAuthResult.passcodeNotSet      => 'Set a device passcode before enabling biometric login.',
      BiometricAuthResult.error               => 'An unexpected biometric error occurred.',
    };
  }
}
