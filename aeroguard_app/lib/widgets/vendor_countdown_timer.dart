import 'dart:async';
import 'package:flutter/material.dart';

class VendorCountdownTimer extends StatefulWidget {
  final int initialSeconds;
  final VoidCallback onExpire;

  const VendorCountdownTimer({
    super.key,
    required this.initialSeconds,
    required this.onExpire,
  });

  @override
  State<VendorCountdownTimer> createState() => _VendorCountdownTimerState();
}

class _VendorCountdownTimerState extends State<VendorCountdownTimer> {
  late int _secondsRemaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.initialSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining <= 0) {
        timer.cancel();
        widget.onExpire();
      } else {
        setState(() => _secondsRemaining--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final double fraction = widget.initialSeconds > 0
        ? (_secondsRemaining / widget.initialSeconds).clamp(0.0, 1.0)
        : 0.0;
    final Color timerColor = fraction > 0.25 ? Colors.orangeAccent : Colors.redAccent;

    return Column(
      children: [
        Text(
          _formatTime(_secondsRemaining),
          style: TextStyle(
            color: timerColor,
            fontSize: 64,
            fontWeight: FontWeight.bold,
            letterSpacing: 4.0,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'SESSION EXPIRES IN',
          style: TextStyle(color: Colors.white30, fontSize: 11, letterSpacing: 2.0),
        ),
      ],
    );
  }
}
