import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';

class ProvisionTokenScreen extends StatefulWidget {
  const ProvisionTokenScreen({super.key});

  @override
  State<ProvisionTokenScreen> createState() => _ProvisionTokenScreenState();
}

class _ProvisionTokenScreenState extends State<ProvisionTokenScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _vendorNameCtrl = TextEditingController();
  final TextEditingController _companyCtrl = TextEditingController();
  int _sessionHours = 4;
  String? _generatedPayload;
  bool _isGenerating = false;

  late AnimationController _qrCtrl;
  late Animation<double> _qrScale;
  late Animation<double> _qrFade;

  static const List<int> _sessionOptions = [2, 4, 6, 8, 12, 24];

  @override
  void initState() {
    super.initState();
    _qrCtrl = AnimationController(
        duration: const Duration(milliseconds: 450), vsync: this);
    _qrScale = Tween<double>(begin: 0.82, end: 1.0).animate(
        CurvedAnimation(parent: _qrCtrl, curve: Curves.easeOutBack));
    _qrFade = CurvedAnimation(parent: _qrCtrl, curve: Curves.easeOut);

    // Rebuild generate button when fields change
    _vendorNameCtrl.addListener(() => setState(() {}));
    _companyCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _vendorNameCtrl.dispose();
    _companyCtrl.dispose();
    _qrCtrl.dispose();
    super.dispose();
  }

  bool get _formValid =>
      _vendorNameCtrl.text.trim().isNotEmpty &&
      _companyCtrl.text.trim().isNotEmpty;

  Future<void> _generateToken() async {
    if (!_formValid) return;
    FocusScope.of(context).unfocus();
    setState(() => _isGenerating = true);

    final vendorName = _vendorNameCtrl.text.trim();
    final company    = _companyCtrl.text.trim();

    final now       = DateTime.now().toUtc();
    final expiresAt = now.add(Duration(hours: _sessionHours)).toIso8601String();
    final rawToken  = 'VENDOR_JIT_${vendorName}_${now.toIso8601String()}';
    final token     = sha256.convert(utf8.encode(rawToken)).toString();

    // Register the session on the backend first.
    try {
      final response = await http
          .post(
            Uri.parse(ApiConstants.vendorProvisionEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'vendor_username':  'vendor_${vendorName.toLowerCase().replaceAll(' ', '_')}',
              'company_name':     company,
              'clearance_level':  'standard',
              'target_device_id': 'vendor_device',
              'valid_until':      expiresAt,
              'qr_token':         token,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        if (mounted) {
          _showProvisionError(
            'Failed to create vendor session (${response.statusCode}). '
            'Check Choreo connectivity.',
          );
        }
        setState(() => _isGenerating = false);
        return;
      }
    } catch (e) {
      if (mounted) {
        _showProvisionError(
          'Central Auth unreachable. Ensure Choreo is deployed and reachable.',
        );
      }
      setState(() => _isGenerating = false);
      return;
    }

    final qrPayload = jsonEncode({
      'type':        'aeroguard_vendor_access',
      'token':       token,
      'vendor_name': vendorName,
      'company':     company,
      'expires_at':  expiresAt,
    });

    setState(() {
      _generatedPayload = qrPayload;
      _isGenerating = false;
    });
    _qrCtrl.forward(from: 0);
  }

  void _showProvisionError(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1421),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
            SizedBox(width: 10),
            Text('Provision Failed',
                style: TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
        content: Text(message,
            style: const TextStyle(color: Color(0xFFC0C7D4), fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK',
                style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w700)),
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
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF050810), Color(0xFF0A1628)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ── AppBar ────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D1421),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.07)),
                        ),
                        child: const Icon(Icons.arrow_back_ios_new,
                            color: Colors.orangeAccent, size: 15),
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Text(
                      'PROVISION VENDOR',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 3.0,
                      ),
                    ),
                  ],
                ),
              ),

              // ── Scrollable body ───────────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Logo + subtitle
                      Row(
                        children: [
                          SizedBox(
                            height: 36,
                            width: 36,
                            child: SvgPicture.asset(
                              'assets/images/Colored Logo.svg',
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'ONE-TIME JIT TOKEN',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2.0,
                                ),
                              ),
                              Text(
                                'Single-use · Expires after session',
                                style: TextStyle(
                                  color: const Color(0xFF94A3B8)
                                      .withValues(alpha: 0.7),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // ── Vendor information form ───────────────────
                      _sectionLabel('VENDOR INFORMATION', Icons.person_outline),
                      const SizedBox(height: 12),

                      _buildField(
                        controller: _vendorNameCtrl,
                        label: 'Vendor Name',
                        icon: Icons.badge_outlined,
                      ),
                      const SizedBox(height: 12),
                      _buildField(
                        controller: _companyCtrl,
                        label: 'Company / Organisation',
                        icon: Icons.business_outlined,
                      ),

                      const SizedBox(height: 22),

                      // ── Session duration ──────────────────────────
                      _sectionLabel(
                          'SESSION DURATION', Icons.timer_outlined),
                      const SizedBox(height: 12),

                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _sessionOptions.map((h) {
                          final selected = _sessionHours == h;
                          return GestureDetector(
                            onTap: () =>
                                setState(() => _sessionHours = h),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: selected
                                    ? Colors.orangeAccent
                                        .withValues(alpha: 0.15)
                                    : const Color(0xFF0D1421),
                                border: Border.all(
                                  color: selected
                                      ? Colors.orangeAccent
                                          .withValues(alpha: 0.7)
                                      : Colors.white
                                          .withValues(alpha: 0.07),
                                  width: selected ? 1.5 : 1,
                                ),
                              ),
                              child: Text(
                                '${h}H',
                                style: TextStyle(
                                  color: selected
                                      ? Colors.orangeAccent
                                      : const Color(0xFF475569),
                                  fontSize: 12,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 28),

                      // ── QR display area ───────────────────────────
                      Center(
                        child: _generatedPayload != null
                            ? ScaleTransition(
                                scale: _qrScale,
                                child: FadeTransition(
                                  opacity: _qrFade,
                                  child: Column(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(18),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius:
                                              BorderRadius.circular(20),
                                          border: Border.all(
                                            color: Colors.orangeAccent,
                                            width: 2.5,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.orangeAccent
                                                  .withValues(alpha: 0.28),
                                              blurRadius: 28,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: QrImageView(
                                          data: _generatedPayload!,
                                          version: QrVersions.auto,
                                          size: 180,
                                          backgroundColor: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      // Token summary chips
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          _tokenChip(Icons.person,
                                              _vendorNameCtrl.text.trim()),
                                          const SizedBox(width: 8),
                                          _tokenChip(Icons.access_time,
                                              '${_sessionHours}H SESSION'),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : Container(
                                height: 216,
                                width: 216,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0D1421),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                      color: Colors.orangeAccent
                                          .withValues(alpha: 0.12)),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.qr_code_2,
                                      size: 60,
                                      color: Colors.orangeAccent
                                          .withValues(alpha: 0.2),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'FILL FORM TO GENERATE',
                                      style: TextStyle(
                                        color: Colors.orangeAccent
                                            .withValues(alpha: 0.35),
                                        fontSize: 9,
                                        letterSpacing: 1.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),

                      const SizedBox(height: 24),

                      // ── Generate button ───────────────────────────
                      GestureDetector(
                        onTap: (_formValid && !_isGenerating)
                            ? _generateToken
                            : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          height: 56,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: _isGenerating
                                ? LinearGradient(colors: [
                                    Colors.orangeAccent
                                        .withValues(alpha: 0.5),
                                    Colors.orange.withValues(alpha: 0.5),
                                  ])
                                : _formValid
                                    ? const LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Colors.orangeAccent,
                                          Colors.orange,
                                        ],
                                      )
                                    : LinearGradient(colors: [
                                        const Color(0xFF0D1421),
                                        const Color(0xFF0D1421),
                                      ]),
                            border: _formValid
                                ? null
                                : Border.all(
                                    color: Colors.white
                                        .withValues(alpha: 0.08)),
                            boxShadow: (_formValid && !_isGenerating)
                                ? [
                                    BoxShadow(
                                      color: Colors.orangeAccent
                                          .withValues(alpha: 0.28),
                                      blurRadius: 20,
                                      offset: const Offset(0, 6),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Center(
                            child: _isGenerating
                                ? SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      color: _formValid
                                          ? Colors.black
                                          : Colors.white30,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.sync_lock,
                                        color: _formValid
                                            ? Colors.black
                                            : const Color(0xFF475569),
                                        size: 18,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        _generatedPayload == null
                                            ? 'GENERATE TOKEN'
                                            : 'RE-GENERATE TOKEN',
                                        style: TextStyle(
                                          color: _formValid
                                              ? Colors.black
                                              : const Color(0xFF475569),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 2.5,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 13, color: Colors.orangeAccent.withValues(alpha: 0.7)),
        const SizedBox(width: 7),
        Text(
          text,
          style: TextStyle(
            color: Colors.orangeAccent.withValues(alpha: 0.7),
            fontSize: 10,
            letterSpacing: 2.0,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
            color: Color(0xFF475569), fontSize: 13, letterSpacing: 0.3),
        prefixIcon:
            Icon(icon, color: const Color(0xFF475569), size: 18),
        filled: true,
        fillColor: const Color(0xFF080E1A),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              BorderSide(color: Colors.white.withValues(alpha: 0.07)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: Colors.orangeAccent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
    );
  }

  Widget _tokenChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: Colors.orangeAccent.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: Colors.orangeAccent),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.orangeAccent,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
