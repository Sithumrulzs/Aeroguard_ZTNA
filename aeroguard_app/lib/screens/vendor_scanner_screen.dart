import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../config/transitions.dart';
import '../services/location_service.dart';
import 'vendor_dashboard.dart';

class VendorScannerScreen extends StatefulWidget {
  const VendorScannerScreen({super.key});

  @override
  State<VendorScannerScreen> createState() => _VendorScannerScreenState();
}

class _VendorScannerScreenState extends State<VendorScannerScreen> {
  bool _isScanned = false;

  void _onDetect(BarcodeCapture capture) async {
    if (_isScanned) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    final String raw = barcodes.first.rawValue!;
    debugPrint('[+] Scanned token: $raw');

    // Parse and validate the AeroGuard vendor token
    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _showError('Invalid QR code — not an AeroGuard token.');
      return;
    }

    if (data['type'] != 'aeroguard_vendor_access') {
      _showError('Unrecognised token type.');
      return;
    }

    // Check expiry
    try {
      final expires = DateTime.parse(data['expires_at'] as String);
      if (DateTime.now().toUtc().isAfter(expires)) {
        _showError('Token expired. Request a new one from the admin.');
        return;
      }
    } catch (_) {
      _showError('Token has no valid expiry field.');
      return;
    }

    setState(() => _isScanned = true);

    // Capture vendor GPS at login (QR scan = vendor auth event).
    LocationService.sendVendorLocation(data['token'] as String);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Welcome, ${data['vendor_name']} — Initiating secure tunnel...',
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.orangeAccent,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );

    Navigator.pushReplacement(
      context,
      slideUpRoute(VendorDashboard(
        vendorName: data['vendor_name'] as String,
        company: data['company'] as String,
        token: data['token'] as String,
        expiresAt: data['expires_at'] as String,
      )),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFFEF4444),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('SCAN JIT TOKEN', style: TextStyle(color: Colors.orangeAccent, letterSpacing: 2.0, fontSize: 16, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.orangeAccent),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 1. THE CAMERA FEED (Fixed: overlayBuilder removed, now handled by Stack)
          MobileScanner(
            onDetect: _onDetect,
          ),
          
          // 2. THE CINEMATIC OVERLAY (Stacked directly on top)
          Container(
            decoration: const ShapeDecoration(
              shape: _ScannerOverlayShape(
                borderColor: Colors.orangeAccent,
                borderRadius: 12,
                borderLength: 40,
                borderWidth: 8,
                cutOutSize: 260,
                overlayColor: Colors.black87,
              ),
            ),
          ),
          
          // 3. BRANDING / INSTRUCTIONS
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Container(
                  height: 60,
                  width: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.orangeAccent.withValues(alpha: 0.4), blurRadius: 20)],
                  ),
                  // Tinting your logo orange for the Vendor UI
                  child: SvgPicture.asset(
                    'assets/images/Light Logo.svg',
                    colorFilter: const ColorFilter.mode(Colors.orangeAccent, BlendMode.srcIn),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Align the Admin QR Code within the frame.',
                  style: TextStyle(color: Colors.white70, letterSpacing: 1.0),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}

// Custom Shape for the Cinematic Scanner Cutout
class _ScannerOverlayShape extends ShapeBorder {
  final Color borderColor;
  final double borderWidth;
  final Color overlayColor;
  final double borderRadius;
  final double borderLength;
  final double cutOutSize;

  const _ScannerOverlayShape({
    this.borderColor = Colors.red,
    this.borderWidth = 3.0,
    this.overlayColor = const Color.fromRGBO(0, 0, 0, 80),
    this.borderRadius = 0,
    this.borderLength = 40,
    this.cutOutSize = 250,
  });

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.all(10);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..fillType = PathFillType.evenOdd..addPath(getOuterPath(rect), Offset.zero);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    Path path = Path()..addRect(rect);
    rect = Rect.fromCenter(center: rect.center, width: cutOutSize, height: cutOutSize);
    path.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(borderRadius)));
    return path..fillType = PathFillType.evenOdd;
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    var paint = Paint()..color = overlayColor..style = PaintingStyle.fill;
    canvas.drawPath(getOuterPath(rect), paint);
    
    var borderPaint = Paint()..color = borderColor..style = PaintingStyle.stroke..strokeWidth = borderWidth;
    var cutOutRect = Rect.fromCenter(center: rect.center, width: cutOutSize, height: cutOutSize);
    
    // Draw the 4 corners of the reticle
    canvas.drawLine(cutOutRect.topLeft, cutOutRect.topLeft.translate(borderLength, 0), borderPaint);
    canvas.drawLine(cutOutRect.topLeft, cutOutRect.topLeft.translate(0, borderLength), borderPaint);
    
    canvas.drawLine(cutOutRect.topRight, cutOutRect.topRight.translate(-borderLength, 0), borderPaint);
    canvas.drawLine(cutOutRect.topRight, cutOutRect.topRight.translate(0, borderLength), borderPaint);
    
    canvas.drawLine(cutOutRect.bottomLeft, cutOutRect.bottomLeft.translate(borderLength, 0), borderPaint);
    canvas.drawLine(cutOutRect.bottomLeft, cutOutRect.bottomLeft.translate(0, -borderLength), borderPaint);
    
    canvas.drawLine(cutOutRect.bottomRight, cutOutRect.bottomRight.translate(-borderLength, 0), borderPaint);
    canvas.drawLine(cutOutRect.bottomRight, cutOutRect.bottomRight.translate(0, -borderLength), borderPaint);
  }

  @override
  ShapeBorder scale(double t) => this;
}