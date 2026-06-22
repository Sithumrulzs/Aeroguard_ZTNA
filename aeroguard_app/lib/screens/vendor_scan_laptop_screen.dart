import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../config/api_constants.dart';

/// Scans the QR shown by the generic terminal exe on the vendor's laptop
/// and links it to this vendor's session — the scan itself is the action,
/// no typing, no confirmation tap needed.
class VendorScanLaptopScreen extends StatefulWidget {
  final String token;

  const VendorScanLaptopScreen({super.key, required this.token});

  @override
  State<VendorScanLaptopScreen> createState() => _VendorScanLaptopScreenState();
}

class _VendorScanLaptopScreenState extends State<VendorScanLaptopScreen> {
  bool _busy = false;

  void _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(barcodes.first.rawValue!) as Map<String, dynamic>;
    } catch (_) {
      return; // not JSON — ignore, keep scanning
    }
    if (data['type'] != 'aeroguard_device_pairing') return;
    final pairingCode = data['pairing_code'] as String?;
    if (pairingCode == null || pairingCode.isEmpty) return;

    setState(() => _busy = true);

    try {
      final res = await http
          .post(
            Uri.parse(ApiConstants.pairDeviceEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token_hash':   widget.token,
              'pairing_code': pairingCode,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (res.statusCode == 200) {
        Navigator.pop(context, true);
        return;
      }
      Map<String, dynamic> body = {};
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {}
      _showError(body['detail']?.toString() ?? 'Pairing failed — try again.');
    } catch (_) {
      _showError('Could not reach the server. Check your connection.');
    }
    if (mounted) setState(() => _busy = false);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFFEF4444),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('SCAN LAPTOP',
            style: TextStyle(
                color: Colors.orangeAccent,
                letterSpacing: 2.0,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.orangeAccent),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          if (_busy)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.orangeAccent),
              ),
            ),
          Positioned(
            bottom: 60,
            left: 24,
            right: 24,
            child: const Text(
              'Open the AeroGuard Terminal on your laptop and point the '
              'camera at the QR it shows — pairing happens automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, letterSpacing: 0.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
