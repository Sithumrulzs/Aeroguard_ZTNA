import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../config/theme.dart';
import '../config/transitions.dart';
import '../services/auth_service.dart';
import '../services/biometric_service.dart';
import '../services/enclave_service.dart';
import '../services/location_service.dart';
import 'admin_dashboard.dart';
import 'vendor_scanner_screen.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  bool _isLoading   = false;
  bool _isBioLoading = false;
  bool _obscure     = true;
  bool _biometricReady = false; // true when sensor available + creds saved

  @override
  void initState() {
    super.initState();
    _checkBiometricReadiness();
  }

  Future<void> _checkBiometricReadiness() async {
    final hardwareAvailable = await BiometricService.isAvailable();
    final credentialsSaved  = await AuthService.hasBiometricCredentials();
    if (mounted) {
      setState(() => _biometricReady = hardwareAvailable && credentialsSaved);
    }
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleBiometricLogin() async {
    setState(() => _isBioLoading = true);
    try {
      final result = await BiometricService.authenticate(
        reason: 'AeroGuard ZTNA: Verify your identity to access the datacenter gateway.',
      );

      if (!mounted) return;

      if (result != BiometricAuthResult.success) {
        // Surface a specific, actionable message for every failure mode.
        _showErrorDialog(BiometricService.describeResult(result));
        return;
      }

      // Biometric confirmed — retrieve the stored credentials and log in.
      final creds = await AuthService.getBiometricCredentials();
      if (creds == null) {
        _showErrorDialog('Saved credentials not found. Please sign in with your password.');
        setState(() => _biometricReady = false);
        return;
      }

      final response = await AuthService.login(creds['username']!, creds['password']!);
      if (!mounted) return;

      if (response.success) {
        final username = response.username ?? creds['username']!;
        await EnclaveService.initializeDevice(username);
        final publicKey = await EnclaveService.getPublicKey();
        final deviceId  = await EnclaveService.getDeviceId();
        if (publicKey != null) {
          final bindStatus = await AuthService.registerDevice(username, deviceId, publicKey);
          if (bindStatus == 403) {
            await EnclaveService.clearDevice();
            await AuthService.logout();
            if (mounted) {
              _showErrorDialog('Device limit reached. Contact IT to reset binding.');
            }
            return;
          }
        }
        LocationService.sendToBackend(username);
        if (mounted) {
          Navigator.pushReplacement(context, premiumRoute(const AdminDashboard()));
        }
      } else {
        // Stored password was rejected (e.g. admin changed it server-side).
        // Clear stale credentials and fall back to manual login.
        await AuthService.clearBiometricCredentials();
        setState(() => _biometricReady = false);
        _showErrorDialog('Saved credentials are no longer valid. Please sign in with your password.');
      }
    } finally {
      if (mounted) setState(() => _isBioLoading = false);
    }
  }

  Future<void> _handleLogin() async {
    // Validate inputs
    if (_userCtrl.text.isEmpty || _passCtrl.text.isEmpty) {
      _showErrorDialog('Please enter both username and password');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Explicitly trim the username and store it in a clean variable
      final trimmedUsername = _userCtrl.text.trim();

      // 2. Use the cleaned variable for the login request
      final response = await AuthService.login(trimmedUsername, _passCtrl.text);

      if (!mounted) return;

      if (response.success) {
        final loggedInUsername = response.username ?? trimmedUsername;
        final enteredPassword  = _passCtrl.text;

        // In-memory only, for this session — lets AdminDashboard offer
        // biometric enrollment later without asking for the password again.
        AuthService.cacheSessionPassword(enteredPassword);

        // Generate / verify device keys in the secure vault.
        await EnclaveService.initializeDevice(loggedInUsername);

        // PKI/TOFU device binding — register public key with the backend.
        final publicKey = await EnclaveService.getPublicKey();
        final deviceId  = await EnclaveService.getDeviceId();

        if (publicKey != null) {
          final bindStatus = await AuthService.registerDevice(
            loggedInUsername, deviceId, publicKey,
          );
          if (bindStatus == 403) {
            // Account is locked to a different device — wipe local identity
            // and force the user to contact IT.
            await EnclaveService.clearDevice();
            await AuthService.logout();
            if (mounted) {
              _showErrorDialog(
                'Device limit reached. Contact IT to reset binding.',
              );
            }
            return;
          }
        }

        _userCtrl.clear();
        _passCtrl.clear();

        // Fire-and-forget — does not block navigation.
        LocationService.sendToBackend(loggedInUsername);

        // Offer biometric save on first login if hardware is available,
        // credentials haven't been saved before, and the user hasn't
        // already declined this offer on this device.
        if (mounted) {
          final bioAvailable = await BiometricService.isAvailable();
          final alreadySaved = await AuthService.hasBiometricCredentials();
          final declined     = await AuthService.hasDeclinedBiometric();
          if (bioAvailable && !alreadySaved && !declined && mounted) {
            await _promptBiometricSave(loggedInUsername, enteredPassword);
          }
        }

        if (mounted) {
          Navigator.pushReplacement(
            context,
            premiumRoute(const AdminDashboard()),
          );
        }
      } else {
        _showErrorDialog(response.message);
      }
    } catch (e) {
      _showErrorDialog('Login failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _promptBiometricSave(String username, String password) async {
    final save = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.fingerprint, color: AppColors.brandBlue, size: 22),
            const SizedBox(width: 10),
            Text(
              'Enable Biometric Login',
              style: TextStyle(color: AppColors.inkPrimary, fontSize: 15),
            ),
          ],
        ),
        content: Text(
          'Use your fingerprint to sign in automatically next time.',
          style: TextStyle(color: AppColors.inkSecondary, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'NOT NOW',
              style: TextStyle(color: AppColors.inkSecondary, letterSpacing: 1.0),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'ENABLE',
              style: TextStyle(
                color: AppColors.brandBlue,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ],
      ),
    );

    if (save == true) {
      await AuthService.saveBiometricCredentials(username, password);
    } else {
      // NOT NOW — record the decline so this dialog stops nagging on every
      // future login (AdminDashboard still offers a way back in).
      await AuthService.setBiometricDeclined();
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'Authentication Failed',
          style: TextStyle(color: AppColors.inkPrimary),
        ),
        content: Text(
          message,
          style: TextStyle(color: AppColors.inkSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('OK', style: TextStyle(color: AppColors.brandBlue)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceMuted,
      body: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 28.0,
                vertical: 48.0,
              ),
                child: Column(
                  children: [
                    // ── Header ──────────────────────────────────────
                    Container(
                      height: 78,
                      width: 78,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        shape: BoxShape.circle,
                        boxShadow: AppColors.softShadow(opacity: 0.14),
                      ),
                      child: SvgPicture.asset(
                        'assets/images/Colored Logo.svg',
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'AEROGUARD',
                      style: TextStyle(
                        color: AppColors.inkPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 8.0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'COMMAND ACCESS',
                      style: TextStyle(
                        color: AppColors.brandBlue,
                        fontSize: 10,
                        letterSpacing: 4.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),

                    const SizedBox(height: 52),

                    // ── Form card ───────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: AppColors.border),
                        boxShadow: AppColors.softShadow(),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AUTHENTICATE',
                            style: TextStyle(
                              color: AppColors.inkSecondary,
                              fontSize: 10,
                              letterSpacing: 3.0,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 22),

                          _buildField(
                            controller: _userCtrl,
                            label: 'Network ID',
                            icon: Icons.badge_outlined,
                          ),
                          const SizedBox(height: 14),
                          _buildField(
                            controller: _passCtrl,
                            label: 'Passphrase',
                            icon: Icons.lock_outline,
                            obscure: _obscure,
                            suffix: IconButton(
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: const Color(0xFF475569),
                                size: 17,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),

                          const SizedBox(height: 26),

                          // Authorize button
                          GestureDetector(
                            onTap: _isLoading ? null : _handleLogin,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: 56,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                gradient: _isLoading
                                    ? LinearGradient(
                                        colors: [
                                          AppColors.brandBlue,
                                          AppColors.brandBlueDark,
                                        ],
                                      )
                                    : AppColors.blueButtonGradient,
                                boxShadow: _isLoading
                                    ? null
                                    : AppColors.softShadow(opacity: 0.32),
                              ),
                              child: Center(
                                child: _isLoading
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text(
                                        'AUTHORIZE',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 3.0,
                                        ),
                                      ),
                              ),
                            ),
                          ),

                          // ── Biometric login — visible only after first
                          //    password login when sensor + creds are ready ──
                          if (_biometricReady) ...[
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(child: Divider(color: AppColors.border)),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text(
                                    'OR',
                                    style: TextStyle(
                                      color: AppColors.inkFaint,
                                      fontSize: 10,
                                      letterSpacing: 2.0,
                                    ),
                                  ),
                                ),
                                Expanded(child: Divider(color: AppColors.border)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            GestureDetector(
                              onTap: _isBioLoading ? null : _handleBiometricLogin,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                height: 52,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: AppColors.brandBlue.withValues(alpha: 0.06),
                                  border: Border.all(
                                    color: AppColors.brandBlue.withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Center(
                                  child: _isBioLoading
                                      ? SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            color: AppColors.brandBlue,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.fingerprint,
                                              color: AppColors.brandBlue,
                                              size: 22,
                                            ),
                                            const SizedBox(width: 10),
                                            Text(
                                              'BIOMETRIC LOGIN',
                                              style: TextStyle(
                                                color: AppColors.brandBlue,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 2.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 52),

                    // ── Vendor access ───────────────────────────────
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        slideUpRoute(const VendorScannerScreen()),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFFDBA74)),
                          color: const Color(0xFFFFF4E5),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.qr_code_scanner,
                              color: Color(0xFFC2410C),
                              size: 16,
                            ),
                            SizedBox(width: 10),
                            Text(
                              'VENDOR ACCESS',
                              style: TextStyle(
                                color: Color(0xFFC2410C),
                                fontSize: 12,
                                letterSpacing: 2.0,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TextStyle(color: AppColors.inkPrimary, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: AppColors.inkSecondary,
          fontSize: 13,
          letterSpacing: 0.3,
        ),
        prefixIcon: Icon(icon, color: AppColors.inkSecondary, size: 18),
        suffixIcon: suffix,
        filled: true,
        fillColor: AppColors.surfaceMuted,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: AppColors.brandBlue, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
    );
  }
}
