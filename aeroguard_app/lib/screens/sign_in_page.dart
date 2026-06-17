import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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

class _SignInPageState extends State<SignInPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  bool _isLoading   = false;
  bool _isBioLoading = false;
  bool _obscure     = true;
  bool _biometricReady = false; // true when sensor available + creds saved

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      duration: const Duration(milliseconds: 700),
      vsync: this,
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOutCubic));
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
    _fadeCtrl.dispose();
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

        // Offer biometric save on first login if hardware is available
        // and credentials haven't been saved before.
        if (mounted) {
          final bioAvailable = await BiometricService.isAvailable();
          final alreadySaved = await AuthService.hasBiometricCredentials();
          if (bioAvailable && !alreadySaved && mounted) {
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
        backgroundColor: const Color(0xFF0D1421),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.fingerprint, color: Color(0xFF00C3FF), size: 22),
            SizedBox(width: 10),
            Text(
              'Enable Biometric Login',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
        content: const Text(
          'Use your fingerprint to sign in automatically next time.',
          style: TextStyle(color: Color(0xFFC0C7D4), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'NOT NOW',
              style: TextStyle(color: Color(0xFF475569), letterSpacing: 1.0),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'ENABLE',
              style: TextStyle(
                color: Color(0xFF00C3FF),
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
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1421),
        title: const Text(
          'Authentication Failed',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          message,
          style: const TextStyle(color: Color(0xFFC0C7D4)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: Color(0xFF00C3FF))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050810),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF050810), Color(0xFF0A1628)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SlideTransition(
              position: _slideAnim,
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
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF00C3FF,
                            ).withValues(alpha: 0.18),
                            blurRadius: 44,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: SvgPicture.asset(
                        'assets/images/Colored Logo.svg',
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'AEROGUARD',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 8.0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'COMMAND ACCESS',
                      style: TextStyle(
                        color: Color(0xFF475569),
                        fontSize: 10,
                        letterSpacing: 4.0,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    const SizedBox(height: 52),

                    // ── Form card ───────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D1421),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: const Color(0xFF00C3FF).withValues(alpha: 0.1),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'AUTHENTICATE',
                            style: TextStyle(
                              color: Color(0xFF475569),
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
                                    ? const LinearGradient(
                                        colors: [
                                          Color(0xFF00A8DD),
                                          Color(0xFF0044CC),
                                        ],
                                      )
                                    : const LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Color(0xFF00C3FF),
                                          Color(0xFF0055FF),
                                        ],
                                      ),
                                boxShadow: _isLoading
                                    ? null
                                    : [
                                        BoxShadow(
                                          color: const Color(
                                            0xFF00C3FF,
                                          ).withValues(alpha: 0.28),
                                          blurRadius: 20,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                              ),
                              child: Center(
                                child: _isLoading
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.black,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text(
                                        'AUTHORIZE',
                                        style: TextStyle(
                                          color: Colors.black,
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
                                Expanded(
                                  child: Divider(
                                    color: Colors.white.withValues(alpha: 0.07),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text(
                                    'OR',
                                    style: TextStyle(
                                      color: const Color(0xFF475569).withValues(alpha: 0.7),
                                      fontSize: 10,
                                      letterSpacing: 2.0,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Divider(
                                    color: Colors.white.withValues(alpha: 0.07),
                                  ),
                                ),
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
                                  color: const Color(0xFF00C3FF).withValues(alpha: 0.05),
                                  border: Border.all(
                                    color: const Color(0xFF00C3FF).withValues(alpha: 0.25),
                                  ),
                                ),
                                child: Center(
                                  child: _isBioLoading
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            color: Color(0xFF00C3FF),
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.fingerprint,
                                              color: Color(0xFF00C3FF),
                                              size: 22,
                                            ),
                                            SizedBox(width: 10),
                                            Text(
                                              'BIOMETRIC LOGIN',
                                              style: TextStyle(
                                                color: Color(0xFF00C3FF),
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
                          border: Border.all(
                            color: Colors.orangeAccent.withValues(alpha: 0.2),
                          ),
                          color: Colors.orangeAccent.withValues(alpha: 0.03),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.qr_code_scanner,
                              color: Colors.orangeAccent,
                              size: 16,
                            ),
                            SizedBox(width: 10),
                            Text(
                              'VENDOR ACCESS',
                              style: TextStyle(
                                color: Colors.orangeAccent,
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
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
          color: Color(0xFF475569),
          fontSize: 13,
          letterSpacing: 0.3,
        ),
        prefixIcon: Icon(icon, color: const Color(0xFF475569), size: 18),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF080E1A),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00C3FF), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
    );
  }
}
