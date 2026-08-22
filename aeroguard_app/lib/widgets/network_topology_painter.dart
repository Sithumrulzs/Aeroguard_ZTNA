import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/theme_controller.dart';

/// Single edit point for the topology's theming. Every getter here is
/// theme-reactive (mirrors `AppColors` in config/theme.dart — same
/// `ThemeController.instance.isDark.value` switch, same "plain static
/// getter, not an InheritedWidget" reasoning) so this card follows the
/// app's light/dark toggle instead of staying pinned to the old
/// dark-only palette.
class TopoColors {
  TopoColors._();

  static bool get _dark => ThemeController.instance.isDark.value;

  // ── card shell ──────────────────────────────────────────────────────
  static List<Color> get cardGradient => _dark
      ? const [Color(0xFF0D1421), Color(0xFF0B111C)]
      : const [Color(0xFFFFFFFF), Color(0xFFFAFBFE)];
  static Color get cardBorder => _dark ? const Color(0x12FFFFFF) : const Color(0x14142F37);
  static Color get divider => _dark ? const Color(0x0DFFFFFF) : const Color(0x0A142F37);

  // ── text ────────────────────────────────────────────────────────────
  static Color get textPrimary   => _dark ? const Color(0xFFF3F6FB) : const Color(0xFF16202E);
  static Color get textSecondary => _dark ? const Color(0xFF8996AC) : const Color(0xFF64728A);
  static Color get textFaint     => _dark ? const Color(0xFF546076) : const Color(0xFF9AA6B8);

  // ── accents ─────────────────────────────────────────────────────────
  // brandBlue is deliberately identical in both modes (per spec) — it's
  // the app's one constant brand color; only the deeper/muted tones
  // shift for light-mode contrast.
  static const Color brandBlue = Color(0xFF2F6FEE);
  static Color get amber    => _dark ? const Color(0xFFFFAB40) : const Color(0xFFB36B00);
  static Color get alertRed => _dark ? const Color(0xFFEF5B5B) : const Color(0xFFC23434);
  static Color get secure   => const Color(0xFF10B981);

  // Kept for call sites still expecting the old names.
  static Color get admin  => brandBlue;
  static Color get vendor => amber;
  static Color get danger => alertRed;
  static Color get warn   => amber;

  /// Node/pill fill — a flat translucent wash in dark mode, a two-stop
  /// pastel gradient in light mode (flat translucency reads as murky on
  /// white; a gradient is what the spec actually calls for there).
  static Gradient tint(TopoAccent accent) {
    if (_dark) {
      final c = _accentColor(accent);
      final a = switch (accent) {
        TopoAccent.blue => 0.16,
        TopoAccent.amber => 0.14,
        TopoAccent.red => 0.14,
        TopoAccent.neutral => 0.10,
      };
      return LinearGradient(colors: [c.withValues(alpha: a), c.withValues(alpha: a * 0.7)]);
    }
    return switch (accent) {
      TopoAccent.blue => const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFFEAF1FF), Color(0xFFDCE9FF)]),
      TopoAccent.amber => const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFFFFF6E9), Color(0xFFFFEDD3)]),
      TopoAccent.red => const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFFFFF0EF), Color(0xFFFFE1DF)]),
      TopoAccent.neutral => LinearGradient(
          colors: [textSecondary.withValues(alpha: 0.10), textSecondary.withValues(alpha: 0.04)]),
    };
  }

  static Color _accentColor(TopoAccent accent) => switch (accent) {
        TopoAccent.blue => brandBlue,
        TopoAccent.amber => amber,
        TopoAccent.red => alertRed,
        TopoAccent.neutral => textSecondary,
      };
}

/// The four-color family every node/edge/pill ultimately resolves to.
enum TopoAccent { blue, amber, red, neutral }

/// A node's presentation state — deliberately separate from the raw
/// gateway/data signal, so the drawing code has one shared rule ("active
/// = solid + accent tint, standby/offline = dashed + accent tint") rather
/// than four one-off widgets each hand-rolling their own look.
enum NodeStatus { active, standby, offline }

/// Gateway health as the topology (and the card's header pill) understands
/// it — a smaller state set than the top Overview banner's, scoped to what
/// this card actually needs to color itself correctly.
enum GatewayStatus { checking, offline, unsecured, secure }

/// Which node this graph currently represents (used for tap targets and the
/// press-scale feedback drawn by the painter).
enum TopoNode { admin, vendor, gateway, datacenter }

/// Which connection is currently carrying a "sending" packet flash. Idle
/// (none) the vast majority of the time — packets only travel when a real
/// knock event fires, never as ambient decoration (deliberately not the
/// always-on animated dot a generic mockup might show: this app only
/// animates real Zero Trust traffic, never fakes activity).
enum TopoSegment { none, adminToGateway, vendorToGateway, gatewayToDatacenter }

/// Fractional node layout — positions scale with the CustomPaint's actual
/// size so the diagram never breaks on a narrow screen; radii stay literal
/// since they're already small and scaling them by width looks odd.
class TopoLayout {
  TopoLayout._();

  static const Offset adminFrac   = Offset(0.18, 0.24);
  static const Offset vendorFrac  = Offset(0.18, 0.78);
  static const Offset gatewayFrac = Offset(0.52, 0.50);
  static const Offset dcFrac      = Offset(0.87, 0.50);

  static const double adminRadius   = 32;
  static const double vendorRadius  = 32;
  static const double gatewayRadius = 40;
  static const double dcRadius      = 30;

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

  // Gateway's own color reflects its real sub-state (secure/unsecured/
  // checking) — but critically, it never goes red for a connectivity
  // failure. If this card is rendering at all, the gateway itself was
  // reached; a failed downstream check is a datacenter problem, not a
  // gateway one, and painting the gateway red for it was the exact bug
  // being fixed (both nodes rendering identically red with no way to
  // tell which one actually failed).
  Color get _gatewayColor => switch (status) {
        GatewayStatus.secure    => TopoColors.secure,
        GatewayStatus.unsecured => TopoColors.amber,
        GatewayStatus.offline   => TopoColors.brandBlue,
        GatewayStatus.checking  => TopoColors.textSecondary,
      };

  TopoAccent get _gatewayAccent => switch (status) {
        GatewayStatus.secure    => TopoAccent.blue, // secure = same calm blue family visually; the green ring/pulse elsewhere already signals "secured"
        GatewayStatus.unsecured => TopoAccent.amber,
        GatewayStatus.offline   => TopoAccent.blue,
        GatewayStatus.checking  => TopoAccent.neutral,
      };

  // Datacenter is the node that actually carries the failure signal —
  // it's the one thing downstream of the gateway this app can't reach
  // when the health check fails, so it's the one that goes red.
  Color get _dcColor => switch (status) {
        GatewayStatus.offline  => TopoColors.alertRed,
        GatewayStatus.checking => TopoColors.textSecondary,
        _                      => TopoColors.brandBlue,
      };

  NodeStatus get _dcStatus => switch (status) {
        GatewayStatus.offline  => NodeStatus.offline,
        GatewayStatus.checking => NodeStatus.standby,
        _                      => NodeStatus.active,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final admin   = TopoLayout.resolve(size, TopoLayout.adminFrac);
    final vendor  = TopoLayout.resolve(size, TopoLayout.vendorFrac);
    final gateway = TopoLayout.resolve(size, TopoLayout.gatewayFrac);
    final dc      = TopoLayout.resolve(size, TopoLayout.dcFrac);
    final gwColor = _gatewayColor;
    final dcColor = _dcColor;
    final dcOffline = _dcStatus == NodeStatus.offline;

    // 0 — faint decorative concentric rings centered on the gateway,
    // static (not tied to any animation) — pure atmosphere.
    final ringStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = TopoColors.brandBlue.withValues(alpha: 0.07);
    for (final r in [TopoLayout.gatewayRadius + 24, TopoLayout.gatewayRadius + 56, TopoLayout.gatewayRadius + 88]) {
      canvas.drawCircle(gateway, r, ringStroke);
    }

    // 1 — connections, drawn first so nodes sit on top of them.
    _drawConnection(canvas, admin, gateway, TopoColors.brandBlue.withValues(alpha: adminCount == 0 ? 0.30 : 0.55),
        dashed: adminCount == 0);
    _drawConnection(canvas, vendor, gateway, TopoColors.amber.withValues(alpha: vendorCount == 0 ? 0.35 : 0.55),
        dashed: vendorCount == 0);
    // Gateway → Datacenter: an arrowhead at the datacenter end always —
    // Zero Trust means this link is never "just open", it's either
    // actively permitting verified traffic or explicitly blocked/down.
    _drawConnection(canvas, gateway, dc, dcColor.withValues(alpha: dcOffline ? 0.6 : 0.45),
        dashed: dcOffline, arrow: true);

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
    _drawNode(canvas, admin, TopoLayout.adminRadius, TopoAccent.blue,
        icon: Icons.verified_user_rounded,
        nodeStatus: adminCount == 0 ? NodeStatus.standby : NodeStatus.active,
        node: TopoNode.admin);
    _drawBadge(canvas, admin, TopoLayout.adminRadius, '$adminCount', TopoColors.brandBlue);
    _drawLabel(canvas, admin, TopoLayout.adminRadius, 'ADMINS');

    _drawNode(canvas, vendor, TopoLayout.vendorRadius, TopoAccent.amber,
        icon: Icons.lock_rounded,
        nodeStatus: vendorCount == 0 ? NodeStatus.standby : NodeStatus.active,
        node: TopoNode.vendor);
    _drawBadge(canvas, vendor, TopoLayout.vendorRadius, '$vendorCount', TopoColors.amber);
    _drawLabel(canvas, vendor, TopoLayout.vendorRadius, 'VENDORS');

    // No icon painted here — the gateway node's mark is the AeroGuard
    // logo, layered on top as a widget by NetworkTopologyCard instead of
    // a MaterialIcons glyph drawn on this canvas.
    _drawNode(canvas, gateway, TopoLayout.gatewayRadius, _gatewayAccent,
        icon: null, nodeStatus: NodeStatus.active, node: TopoNode.gateway, ringColor: gwColor);
    _drawLabel(canvas, gateway, TopoLayout.gatewayRadius, 'GATEWAY');

    _drawNode(canvas, dc, TopoLayout.dcRadius,
        dcOffline ? TopoAccent.red : TopoAccent.blue,
        icon: Icons.dns_rounded, nodeStatus: _dcStatus, node: TopoNode.datacenter, quiet: !dcOffline);
    if (dcOffline) _drawOfflineBadge(canvas, dc, TopoLayout.dcRadius);
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

  void _drawConnection(Canvas canvas, Offset start, Offset end, Color color, {
    required bool dashed,
    bool arrow = false,
  }) {
    final path = _bezier(start, end);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = color;
    canvas.drawPath(dashed ? _dashPath(path) : path, paint);

    if (!arrow) return;
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final tangent = metric.getTangentForOffset(metric.length - 1);
    if (tangent == null) return;
    final angle = tangent.angle;
    final tip = tangent.position;
    const headLen = 6.0;
    const headSpread = 0.5;
    final left = tip - Offset(math.cos(angle - headSpread), math.sin(angle - headSpread)) * headLen;
    final right = tip - Offset(math.cos(angle + headSpread), math.sin(angle + headSpread)) * headLen;
    final arrowPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(right.dx, right.dy);
    canvas.drawPath(arrowPath, paint);
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
    TopoAccent accent, {
    required IconData? icon,
    required NodeStatus nodeStatus,
    required TopoNode node,
    bool quiet = false,
    Color? ringColor,
  }) {
    final pressed = node == pressedNode;
    if (pressed) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(0.96);
      canvas.translate(-center.dx, -center.dy);
    }

    final accentColor = switch (accent) {
      TopoAccent.blue => TopoColors.brandBlue,
      TopoAccent.amber => TopoColors.amber,
      TopoAccent.red => TopoColors.alertRed,
      TopoAccent.neutral => TopoColors.textSecondary,
    };

    // Pastel tinted fill (gradient in light mode, flat wash in dark).
    final fillPaint = Paint()..shader = TopoColors.tint(accent).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, fillPaint);

    // Specular highlight — a soft bright glint near the top-left, like
    // light catching the surface of a glass sphere.
    final highlightCenter = center + Offset(-radius * 0.35, -radius * 0.35);
    canvas.drawCircle(
      highlightCenter,
      radius * 0.5,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.30), Colors.white.withValues(alpha: 0.0)],
        ).createShader(Rect.fromCircle(center: highlightCenter, radius: radius * 0.5)),
    );

    final dashed = nodeStatus != NodeStatus.active;
    final strokeAlpha = switch (nodeStatus) {
      NodeStatus.active  => quiet ? 0.5 : 0.85,
      NodeStatus.standby => 0.45,
      NodeStatus.offline => 0.55,
    };
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = quiet ? 1.2 : 1.6
      ..color = accentColor.withValues(alpha: strokeAlpha);
    if (dashed) {
      final circlePath = Path()..addOval(Rect.fromCircle(center: center, radius: radius));
      canvas.drawPath(_dashPath(circlePath), strokePaint);
    } else {
      canvas.drawCircle(center, radius, strokePaint);
    }

    if (icon != null) _paintIcon(canvas, icon, center, radius * 0.62, ringColor ?? accentColor);

    if (pressed) canvas.restore();
  }

  void _drawBadge(Canvas canvas, Offset nodeCenter, double nodeRadius, String text, Color color) {
    final badgeCenter = nodeCenter + Offset(nodeRadius * 0.72, -nodeRadius * 0.72);
    const badgeRadius = 11.0;
    canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = color);
    final tp = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, badgeCenter - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawOfflineBadge(Canvas canvas, Offset nodeCenter, double nodeRadius) {
    final badgeCenter = nodeCenter + Offset(nodeRadius * 0.72, nodeRadius * 0.72);
    const badgeRadius = 10.0;
    canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = TopoColors.cardGradient.first);
    canvas.drawCircle(
      badgeCenter, badgeRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = TopoColors.alertRed,
    );
    _paintIcon(canvas, Icons.close_rounded, badgeCenter, 12, TopoColors.alertRed);
  }

  void _drawLabel(Canvas canvas, Offset center, double radius, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: TopoColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + radius + 10));
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
