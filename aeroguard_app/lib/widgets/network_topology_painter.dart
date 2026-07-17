import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Single edit point for the topology's theming — every color the card and
/// painter use lives here, mapped onto AeroGuard's existing app palette
/// (cyan admin / orange vendor / green-amber-red gateway) rather than a new
/// one, so it stays visually consistent with the rest of the dashboard.
class TopoColors {
  TopoColors._();

  static const Color cardBg     = Color(0xFF0D1421);
  static const Color cardBorder = Color(0x26FFFFFF);
  static const Color divider    = Color(0x0DFFFFFF);

  static const Color textPrimary   = Colors.white;
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted     = Color(0xFF475569);

  static const Color admin  = Color(0xFF00C3FF);
  static const Color vendor = Colors.orangeAccent;
  static const Color secure = Color(0xFF10B981);
  static const Color danger = Color(0xFFEF4444);
  static const Color warn   = Color(0xFFF59E0B);
}

/// Gateway health as the topology (and the card's header pill) understands
/// it — a smaller state set than the top Overview banner's, scoped to what
/// this card actually needs to color itself correctly.
enum GatewayStatus { checking, offline, unsecured, secure }

/// Which node this graph currently represents (used for tap targets and the
/// press-scale feedback drawn by the painter).
enum TopoNode { admin, vendor, gateway, datacenter }

/// Which connection is currently carrying a "sending" packet flash. Idle
/// (none) the vast majority of the time — packets only travel when a real
/// knock event fires, never as ambient decoration.
enum TopoSegment { none, adminToGateway, vendorToGateway, gatewayToDatacenter }

/// Fractional node layout — positions scale with the CustomPaint's actual
/// size so the diagram never breaks on a narrow screen; radii stay literal
/// since they're already small and scaling them by width looks odd.
class TopoLayout {
  TopoLayout._();

  static const Offset adminFrac   = Offset(0.16, 0.26);
  static const Offset vendorFrac  = Offset(0.16, 0.76);
  static const Offset gatewayFrac = Offset(0.52, 0.50);
  static const Offset dcFrac      = Offset(0.88, 0.50);

  static const double adminRadius   = 26;
  static const double vendorRadius  = 26;
  static const double gatewayRadius = 30;
  static const double dcRadius      = 24;

  static Offset resolve(Size size, Offset frac) =>
      Offset(frac.dx * size.width, frac.dy * size.height);
}

class NetworkTopologyPainter extends CustomPainter {
  final int adminCount;
  final int vendorCount;
  final GatewayStatus status;
  final double ringProgress;
  final TopoSegment activeSegment;
  final double packetProgress;
  final Color packetColor;
  final TopoNode? pressedNode;

  const NetworkTopologyPainter({
    required this.adminCount,
    required this.vendorCount,
    required this.status,
    required this.ringProgress,
    required this.activeSegment,
    required this.packetProgress,
    required this.packetColor,
    this.pressedNode,
  });

  Color get _gatewayColor => switch (status) {
        GatewayStatus.secure    => TopoColors.secure,
        GatewayStatus.unsecured => TopoColors.warn,
        GatewayStatus.offline   => TopoColors.danger,
        GatewayStatus.checking  => TopoColors.textSecondary,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final admin   = TopoLayout.resolve(size, TopoLayout.adminFrac);
    final vendor  = TopoLayout.resolve(size, TopoLayout.vendorFrac);
    final gateway = TopoLayout.resolve(size, TopoLayout.gatewayFrac);
    final dc      = TopoLayout.resolve(size, TopoLayout.dcFrac);
    final gwColor = _gatewayColor;
    final linkUp  = status == GatewayStatus.secure || status == GatewayStatus.unsecured;

    // 1 — connections, drawn first so nodes sit on top of them.
    _drawConnection(canvas, admin, gateway, TopoColors.admin.withValues(alpha: 0.35),
        dashed: adminCount == 0);
    _drawConnection(canvas, vendor, gateway, TopoColors.vendor.withValues(alpha: 0.35),
        dashed: vendorCount == 0);
    _drawConnection(canvas, gateway, dc, gwColor.withValues(alpha: 0.35), dashed: !linkUp);

    // 2 — gateway's ambient "alive" ring, only while actually secure.
    if (status == GatewayStatus.secure) {
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = gwColor.withValues(alpha: (1 - ringProgress) * 0.5);
      canvas.drawCircle(gateway, TopoLayout.gatewayRadius + ringProgress * 10, ringPaint);
    }

    // 3 — the event-driven packet flash (only while a real knock is live).
    if (activeSegment != TopoSegment.none) {
      final path = switch (activeSegment) {
        TopoSegment.adminToGateway      => _bezier(admin, gateway),
        TopoSegment.vendorToGateway     => _bezier(vendor, gateway),
        TopoSegment.gatewayToDatacenter => _bezier(gateway, dc),
        TopoSegment.none                => Path(),
      };
      _drawPacket(canvas, path, packetProgress, packetColor);
      if (activeSegment != TopoSegment.gatewayToDatacenter) {
        _drawPacket(canvas, path, packetProgress - 0.22, packetColor.withValues(alpha: 0.5));
      }
    }

    // 4 — nodes on top of everything.
    _drawNode(canvas, admin, TopoLayout.adminRadius, TopoColors.admin,
        icon: Icons.admin_panel_settings_rounded, dashed: adminCount == 0, node: TopoNode.admin);
    _drawBadge(canvas, admin, TopoLayout.adminRadius, '$adminCount', TopoColors.admin);
    _drawLabel(canvas, admin, TopoLayout.adminRadius, 'ADMINS');

    _drawNode(canvas, vendor, TopoLayout.vendorRadius, TopoColors.vendor,
        icon: Icons.badge_rounded, dashed: vendorCount == 0, node: TopoNode.vendor);
    _drawBadge(canvas, vendor, TopoLayout.vendorRadius, '$vendorCount', TopoColors.vendor);
    _drawLabel(canvas, vendor, TopoLayout.vendorRadius, 'VENDORS');

    // No icon painted here — the gateway node's mark is the AeroGuard
    // logo, layered on top as a widget by NetworkTopologyCard instead of
    // a MaterialIcons glyph drawn on this canvas.
    _drawNode(canvas, gateway, TopoLayout.gatewayRadius, gwColor,
        icon: null, dashed: false, node: TopoNode.gateway);
    _drawLabel(canvas, gateway, TopoLayout.gatewayRadius, 'GATEWAY');

    _drawNode(canvas, dc, TopoLayout.dcRadius, gwColor,
        icon: Icons.dns_rounded, dashed: false, node: TopoNode.datacenter, quiet: true);
    _drawLabel(canvas, dc, TopoLayout.dcRadius, 'DATACENTER');
  }

  @override
  bool shouldRepaint(covariant NetworkTopologyPainter old) {
    return old.adminCount != adminCount ||
        old.vendorCount != vendorCount ||
        old.status != status ||
        old.ringProgress != ringProgress ||
        old.activeSegment != activeSegment ||
        old.packetProgress != packetProgress ||
        old.packetColor != packetColor ||
        old.pressedNode != pressedNode;
  }

  // ── geometry ────────────────────────────────────────────────────────────

  Path _bezier(Offset start, Offset end) {
    final dx = (end.dx - start.dx) * 0.5;
    return Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(start.dx + dx, start.dy, end.dx - dx, end.dy, end.dx, end.dy);
  }

  Path _dashPath(Path source, {double dashLength = 4, double gapLength = 3}) {
    final dashed = Path();
    for (final metric in source.computeMetrics()) {
      double distance = 0;
      bool draw = true;
      while (distance < metric.length) {
        final len = draw ? dashLength : gapLength;
        final next = math.min(distance + len, metric.length);
        if (draw) dashed.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next;
        draw = !draw;
      }
    }
    return dashed;
  }

  // ── drawing ─────────────────────────────────────────────────────────────

  void _drawConnection(Canvas canvas, Offset start, Offset end, Color color, {required bool dashed}) {
    final path = _bezier(start, end);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    canvas.drawPath(dashed ? _dashPath(path) : path, paint);
  }

  void _drawPacket(Canvas canvas, Path path, double t, Color color) {
    if (t < 0 || t > 1) return;
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final tangent = metric.getTangentForOffset(metric.length * t);
    if (tangent == null) return;
    final glow = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(tangent.position, 5, glow);
    canvas.drawCircle(tangent.position, 2.5, Paint()..color = color);
  }

  void _drawNode(
    Canvas canvas,
    Offset center,
    double radius,
    Color color, {
    required IconData? icon,
    required bool dashed,
    required TopoNode node,
    bool quiet = false,
  }) {
    final pressed = node == pressedNode;
    if (pressed) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(0.96);
      canvas.translate(-center.dx, -center.dy);
    }

    // Translucent glass fill — a soft radial tint over the canvas
    // background, not a solid color.
    final fillPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.3),
        radius: 1.1,
        colors: [
          color.withValues(alpha: quiet ? 0.22 : 0.30),
          color.withValues(alpha: quiet ? 0.07 : 0.11),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, fillPaint);

    // Specular highlight — a soft bright glint near the top-left, like
    // light catching the surface of a glass sphere. The "premium" touch
    // that keeps a translucent node from reading as a flat tinted circle.
    final highlightCenter = center + Offset(-radius * 0.35, -radius * 0.35);
    canvas.drawCircle(
      highlightCenter,
      radius * 0.5,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.30), Colors.white.withValues(alpha: 0.0)],
        ).createShader(Rect.fromCircle(center: highlightCenter, radius: radius * 0.5)),
    );

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = quiet ? 1.2 : 1.5
      ..color = color.withValues(alpha: quiet ? 0.5 : 0.85);
    if (dashed) {
      final circlePath = Path()..addOval(Rect.fromCircle(center: center, radius: radius));
      canvas.drawPath(_dashPath(circlePath), strokePaint);
    } else {
      canvas.drawCircle(center, radius, strokePaint);
    }

    if (icon != null) _paintIcon(canvas, icon, center, radius * 0.72, color);

    if (pressed) canvas.restore();
  }

  void _drawBadge(Canvas canvas, Offset nodeCenter, double nodeRadius, String text, Color color) {
    final badgeCenter = nodeCenter + Offset(nodeRadius * 0.72, -nodeRadius * 0.72);
    const badgeRadius = 10.0;
    canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = TopoColors.cardBg);
    canvas.drawCircle(
      badgeCenter,
      badgeRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, badgeCenter - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawLabel(Canvas canvas, Offset center, double radius, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: TopoColors.textSecondary,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + radius + 8));
  }

  void _paintIcon(Canvas canvas, IconData icon, Offset center, double size, Color color) {
    final tp = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      )
      ..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }
}
