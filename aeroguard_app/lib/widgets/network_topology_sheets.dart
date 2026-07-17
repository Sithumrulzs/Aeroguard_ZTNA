import 'package:flutter/material.dart';
import '../config/api_constants.dart';
import 'network_topology_painter.dart';

/// Bottom sheets for the Network Topology card — split out purely to keep
/// the card widget itself readable; these are plain functions rather than
/// their own widget classes since they're one-shot presentational content
/// with no state of their own.

String _simpleCase(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

Widget _sheetRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: TopoColors.textSecondary, fontSize: 13)),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );

/// Registered admins / active vendors — plain name list, with an optional
/// "manage" action (used to jump straight to the Vault tab for vendors).
void showTopoListSheet(
  BuildContext context, {
  required String title,
  required IconData icon,
  required Color color,
  required List<String> names,
  required String emptyLabel,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: TopoColors.cardBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 16),
            if (names.isEmpty)
              Text(emptyLabel, style: const TextStyle(color: TopoColors.textMuted, fontSize: 13))
            else
              ...names.map((n) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Icon(Icons.circle, size: 6, color: color),
                      const SizedBox(width: 10),
                      Text(_simpleCase(n), style: const TextStyle(color: Colors.white, fontSize: 14)),
                    ]),
                  )),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  onAction();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: color.withValues(alpha: 0.3)),
                  ),
                  child: Center(
                    child: Text(actionLabel,
                        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Gateway health: reachability, drop-all firewall state, last knock.
void showTopoGatewaySheet(
  BuildContext context, {
  required Color color,
  required String statusSpeech,
  required bool linkUp,
  required String firewallLabel,
  required String lastKnockLabel,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: TopoColors.cardBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.shield_rounded, color: color, size: 20),
              const SizedBox(width: 10),
              const Text('Gateway Health',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 4),
            Text('Gateway is $statusSpeech', style: TextStyle(color: color, fontSize: 12)),
            const SizedBox(height: 18),
            _sheetRow('Gateway IP', ApiConstants.gatewayIp),
            _sheetRow('Reachable', linkUp ? 'YES' : 'NO'),
            _sheetRow('Drop-all firewall', firewallLabel),
            _sheetRow('Last knock', lastKnockLabel),
          ],
        ),
      ),
    ),
  );
}
