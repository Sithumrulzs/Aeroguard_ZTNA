import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';
import '../config/transitions.dart';
import '../screens/provision_token_screen.dart';
import '../services/theme_controller.dart';
import 'gloss_panel.dart';
import 'network_topology_painter.dart';
import 'network_topology_sheets.dart';

/// Plain, testable snapshot of everything the topology needs to render —
/// deliberately has no knowledge of HTTP/polling so it can be constructed
/// directly in a test.
class NetworkTopologyData {
  final int adminCount;
  final int vendorCount;
  final List<String> adminNames;
  final List<String> vendorNames;
  final DateTime? lastKnock;
  final GatewayStatus status;

  const NetworkTopologyData({
    this.adminCount = 0,
    this.vendorCount = 0,
    this.adminNames = const [],
    this.vendorNames = const [],
    this.lastKnock,
    this.status = GatewayStatus.checking,
  });
}

/// Self-contained "Network Topology" card for the Overview screen — polls
/// its own data the same way every sibling panel on this dashboard already
/// does (Timer + setState; the app has no Provider/Riverpod/Bloc layer to
/// plug into), and renders a live, connected admin/vendor → gateway →
/// datacenter graph instead of a flat stat list.
class NetworkTopologyCard extends StatefulWidget {
  /// Optional — lets the card send "view vendors" straight to the Vault
  /// tab's session list instead of just a lightweight name sheet.
  final VoidCallback? onViewVault;

  const NetworkTopologyCard({super.key, this.onViewVault});

  @override
  State<NetworkTopologyCard> createState() => _NetworkTopologyCardState();
}

class _NetworkTopologyCardState extends State<NetworkTopologyCard>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  Timer? _statsTimer;
  Timer? _knockTimer;

  NetworkTopologyData _data = const NetworkTopologyData();
  bool _loading = true;
  bool _relativeTime = true;

  final Set<int> _seenKnockIds = {};
  bool _firstKnockLoad = true;

  late final AnimationController _liveDotCtrl;
  late final AnimationController _ringCtrl;
  late final AnimationController _packetCtrl;

  TopoSegment _activeSegment = TopoSegment.none;
  Color _packetColor = TopoColors.admin;
  TopoNode? _pressedNode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _liveDotCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat(reverse: true);
    _ringCtrl   = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
    _packetCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

    _fetchStats();
    _fetchKnocks();
    _statsTimer = Timer.periodic(const Duration(seconds: 12), (_) => _fetchStats());
    _knockTimer = Timer.periodic(const Duration(seconds: 4), (_) => _fetchKnocks());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statsTimer?.cancel();
    _knockTimer?.cancel();
    _liveDotCtrl.dispose();
    _ringCtrl.dispose();
    _packetCtrl.dispose();
    super.dispose();
  }

  // Screen-off/backgrounded pause for the ambient ring — the packet flash
  // is already event-driven and stops itself, so it needs no lifecycle
  // handling. (Tab-visibility pausing is intentionally out of scope here:
  // the Overview tab lives in the dashboard's IndexedStack, which never
  // gives this widget a non-current route to detect — every other
  // continuously-animating panel already sitting in that stack has the
  // same characteristic, so this matches existing behavior.)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_data.status == GatewayStatus.secure) _ringCtrl.repeat();
    } else {
      _ringCtrl.stop();
    }
  }

  Future<void> _fetchStats() async {
    bool online = false;
    try {
      final res = await http
          .get(Uri.parse(ApiConstants.gatewayHealthUrl))
          .timeout(const Duration(seconds: 4));
      online = res.statusCode == 200;
    } catch (_) {
      online = false;
    }

    GatewayStatus status;
    if (!online) {
      status = GatewayStatus.offline;
    } else {
      // Same drop-all/dark-mode probe as the top Gateway banner: a refused
      // connection to the blackhole port means the firewall is merely
      // closed (responsive), not truly dropping — only a silent timeout
      // means the DROP-all policy is actually active.
      bool secured;
      try {
        final socket = await Socket.connect(
          ApiConstants.gatewayIp, 9999,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
        secured = false;
      } on SocketException catch (e) {
        final code = e.osError?.errorCode;
        secured = !(code == 111 || e.message.toLowerCase().contains('refused'));
      } catch (_) {
        secured = true;
      }
      status = secured ? GatewayStatus.secure : GatewayStatus.unsecured;
    }

    int adminCount           = _data.adminCount;
    int vendorCount          = _data.vendorCount;
    List<String> adminNames  = _data.adminNames;
    List<String> vendorNames = _data.vendorNames;
    DateTime? lastKnock      = _data.lastKnock;

    try {
      final response = await http
          .get(Uri.parse(ApiConstants.dashboardTelemetryEndpoint))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        adminCount  = ((json['registered_admins'] ?? json['active_admins']) as num?)?.toInt() ?? 0;
        vendorCount = (json['active_vendors'] as num?)?.toInt() ?? 0;
        adminNames  = List<String>.from(json['registered_admin_names'] ?? json['active_admin_names'] ?? []);
        vendorNames = List<String>.from(json['active_vendor_names'] ?? []);
        final lastKnockAt = json['last_knock_at'] as String?;
        lastKnock = lastKnockAt != null ? DateTime.tryParse(lastKnockAt)?.toLocal() : null;
      }
    } catch (_) {}

    // This device's own direct probe found no local tunnel, but recent
    // knock activity from anyone (admin or vendor) is proof the gateway
    // itself is alive and working — that's a materially different state
    // from a genuinely unreachable gateway, even though this device can't
    // verify it directly either way.
    if (status == GatewayStatus.offline &&
        lastKnock != null &&
        DateTime.now().difference(lastKnock).inMinutes < 3) {
      status = GatewayStatus.liveRemote;
    }

    if (!mounted) return;

    final wasSecure = _data.status == GatewayStatus.secure;
    setState(() {
      _data = NetworkTopologyData(
        adminCount: adminCount,
        vendorCount: vendorCount,
        adminNames: adminNames,
        vendorNames: vendorNames,
        lastKnock: lastKnock,
        status: status,
      );
      _loading = false;
    });

    final nowSecure = status == GatewayStatus.secure;
    if (nowSecure && !wasSecure) {
      _ringCtrl.repeat();
    } else if (!nowSecure && wasSecure) {
      _ringCtrl.stop();
    }
  }

  /// Polls the combined admin+vendor knock feed purely to detect brand-new
  /// events — the only thing that ever triggers the packet "sending"
  /// animation. Idle topology never shows moving dots.
  Future<void> _fetchKnocks() async {
    try {
      final res = await http
          .get(Uri.parse('${ApiConstants.knockHistoryEndpoint}?limit=5'))
          .timeout(const Duration(seconds: 8));
      if (!mounted || res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final knocks = List<Map<String, dynamic>>.from(data['knocks'] ?? []);
      if (knocks.isEmpty) return;

      if (_firstKnockLoad) {
        for (final k in knocks) {
          final id = k['id'] as int?;
          if (id != null) _seenKnockIds.add(id);
        }
        _firstKnockLoad = false;
        return;
      }

      final fresh = knocks.where((k) {
        final id = k['id'] as int?;
        return id != null && !_seenKnockIds.contains(id);
      }).toList().reversed; // oldest-first, so a burst flashes in order

      bool sawGrant = false;
      for (final k in fresh) {
        final id = k['id'] as int;
        _seenKnockIds.add(id);
        final actor   = k['actor_type'] as String? ?? 'admin';
        final granted = (k['status'] as String? ?? '').startsWith('GRANTED');
        sawGrant = sawGrant || granted;
        await _playFlash(
          actor == 'vendor' ? TopoSegment.vendorToGateway : TopoSegment.adminToGateway,
          actor == 'vendor' ? TopoColors.vendor : TopoColors.admin,
          granted,
        );
      }

      // A grant just landed — the online/offline pill's own 12s timer
      // would otherwise take up to that long to notice, showing "offline"
      // for several seconds right after a knock that plainly just
      // succeeded. This 4s knock poll already caught the grant, so refresh
      // the status right now instead of waiting on the slower timer.
      if (sawGrant && mounted) {
        unawaited(_fetchStats());
      }
    } catch (_) {}
  }

  /// Runs the packet from the knocking actor to the gateway, then — only if
  /// the knock was actually granted — continues it on to the datacenter.
  /// A denied knock's flash stops dead at the gateway, which is the whole
  /// point of Zero Trust: nothing unauthorized ever reaches the datacenter.
  Future<void> _playFlash(TopoSegment segment, Color color, bool granted) async {
    if (!mounted) return;
    setState(() {
      _activeSegment = segment;
      _packetColor   = color;
    });
    await _packetCtrl.forward(from: 0);
    if (!mounted) return;

    if (granted) {
      setState(() {
        _activeSegment = TopoSegment.gatewayToDatacenter;
        _packetColor   = TopoColors.secure;
      });
      await _packetCtrl.forward(from: 0);
      if (!mounted) return;
    }

    setState(() => _activeSegment = TopoSegment.none);
  }

  String _fmtAbsolute(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, $h:$m';
  }

  String get _lastKnockLabel {
    final dt = _data.lastKnock;
    if (dt == null) return '—';
    final diff = DateTime.now().difference(dt);
    if (!_relativeTime || diff.inHours >= 24) return _fmtAbsolute(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  // The pill names what's actually down — datacenter unreachable, never
  // "gateway offline", since the gateway is what served this data in the
  // first place. See NetworkTopologyPainter for the matching node-level
  // reasoning.
  Color get _statusColor => switch (_data.status) {
        GatewayStatus.secure     => TopoColors.secure,
        GatewayStatus.liveRemote => TopoColors.brandBlue,
        GatewayStatus.unsecured  => TopoColors.amber,
        GatewayStatus.offline    => TopoColors.alertRed,
        GatewayStatus.checking   => TopoColors.textFaint,
      };

  String get _statusPillLabel => switch (_data.status) {
        GatewayStatus.secure     => 'Live',
        GatewayStatus.liveRemote => 'Gateway Live',
        GatewayStatus.unsecured  => 'Unsecured',
        GatewayStatus.offline    => 'Datacenter Offline',
        GatewayStatus.checking   => 'Checking',
      };

  String get _statusSpeech => switch (_data.status) {
        GatewayStatus.secure     => 'secured',
        GatewayStatus.liveRemote => 'live — active elsewhere, no local tunnel',
        GatewayStatus.unsecured  => 'online but unsecured',
        GatewayStatus.offline    => 'offline',
        GatewayStatus.checking   => 'checking status',
      };

  // ── interactions ──────────────────────────────────────────────────────

  void _openAdminsSheet() => showTopoListSheet(
        context,
        title: 'Registered Admins',
        icon: Icons.admin_panel_settings_rounded,
        color: TopoColors.admin,
        names: _data.adminNames,
        emptyLabel: 'No admins registered',
      );

  void _openVendorsSheet() {
    if (_data.vendorCount == 0) {
      Navigator.push(context, slideUpRoute(const ProvisionTokenScreen()));
      return;
    }
    showTopoListSheet(
      context,
      title: 'Active Vendors',
      icon: Icons.badge_rounded,
      color: TopoColors.vendor,
      names: _data.vendorNames,
      emptyLabel: 'No active vendors',
      actionLabel: widget.onViewVault != null ? 'MANAGE IN VAULT' : null,
      onAction: widget.onViewVault,
    );
  }

  void _openGatewaySheet() {
    final firewallLabel = switch (_data.status) {
      GatewayStatus.secure    => 'ACTIVE',
      GatewayStatus.unsecured => 'INACTIVE',
      _                       => '—',
    };
    showTopoGatewaySheet(
      context,
      color: _statusColor,
      statusSpeech: _statusSpeech,
      linkUp: _data.status == GatewayStatus.secure || _data.status == GatewayStatus.unsecured,
      firewallLabel: firewallLabel,
      lastKnockLabel: _data.lastKnock != null ? _fmtAbsolute(_data.lastKnock!) : '—',
    );
  }

  // ── build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          // ~155° — down and slightly leftward, per spec.
          begin: Alignment.topRight,
          end: Alignment(-0.6, 1),
          colors: TopoColors.cardGradient,
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: TopoColors.cardBorder),
        boxShadow: ThemeController.instance.isDark.value
            ? [const BoxShadow(color: Color(0x59_0D1421), blurRadius: 60, offset: Offset(0, 24))]
            : [
                const BoxShadow(color: Color(0x1F1E325A), blurRadius: 55, offset: Offset(0, 24)),
                const BoxShadow(color: Color(0x0D1E325A), blurRadius: 10, offset: Offset(0, 2)),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
            child: SizedBox(
              height: 260,
              child: _loading ? _buildLoading() : _buildGraph(),
            ),
          ),
          Divider(color: TopoColors.divider, height: 1),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildLoading() => Center(
        child: SizedBox(
          height: 22,
          width: 22,
          child: CircularProgressIndicator(strokeWidth: 1.5, valueColor: AlwaysStoppedAnimation(TopoColors.brandBlue)),
        ),
      );

  // Title moved out of the card entirely — see the "NETWORK MAP" section
  // label admin_dashboard.dart places above this widget, same treatment as
  // "SECURITY POSTURE" above the metric cards. This header is now just the
  // live status pill, right-aligned. (A left-side gateway identifier — e.g.
  // "SITHUM-GW-01" — belongs here too per the design mockup, but no
  // backend field for gateway identity exists yet to source it from; adding
  // one hardcoded would just be fake data. Slot's ready for it once a real
  // field exists.)
  Widget _buildHeader() {
    final animated = _data.status == GatewayStatus.secure;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: TopoColors.divider))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              gradient: glassTint(_statusColor),
              border: Border.all(color: _statusColor.withValues(alpha: 0.45)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _liveDotCtrl,
                  builder: (context, _) => Container(
                    height: 6,
                    width: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _statusColor.withValues(alpha: animated ? (0.4 + _liveDotCtrl.value * 0.6) : 1.0),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(_statusPillLabel,
                    style: TextStyle(color: _statusColor, fontSize: 11, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGraph() {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([_ringCtrl, _packetCtrl]),
              builder: (context, _) => CustomPaint(
                size: size,
                painter: NetworkTopologyPainter(
                  adminCount: _data.adminCount,
                  vendorCount: _data.vendorCount,
                  status: _data.status,
                  ringProgress: _ringCtrl.value,
                  activeSegment: _activeSegment,
                  packetProgress: _packetCtrl.value,
                  packetColor: _packetColor,
                  pressedNode: _pressedNode,
                ),
              ),
            ),
          ),
        ),
        _gatewayLogo(size),
        _nodeTapTarget(size, TopoLayout.adminFrac, TopoLayout.adminRadius, TopoNode.admin,
            'Admins, ${_data.adminCount} registered, double tap to view', _openAdminsSheet),
        _nodeTapTarget(size, TopoLayout.vendorFrac, TopoLayout.vendorRadius, TopoNode.vendor,
            'Vendors, ${_data.vendorCount} active, double tap to view', _openVendorsSheet),
        _nodeTapTarget(size, TopoLayout.gatewayFrac, TopoLayout.gatewayRadius, TopoNode.gateway,
            'Gateway, $_statusSpeech, double tap for health details', _openGatewaySheet),
      ]);
    });
  }

  // The gateway node's mark is the AeroGuard logo itself rather than a
  // generic shield glyph — layered on top of the painted circle as a
  // widget (the painter draws no icon for this node at all), tinted to
  // match the same live status color as everything else on that node.
  Widget _gatewayLogo(Size size) {
    final center = TopoLayout.resolve(size, TopoLayout.gatewayFrac);
    final logoSize = TopoLayout.gatewayRadius * 0.95;
    return Positioned(
      left: center.dx - logoSize / 2,
      top: center.dy - logoSize / 2,
      width: logoSize,
      height: logoSize,
      child: IgnorePointer(
        child: SvgPicture.asset(
          'assets/images/Light Logo.svg',
          colorFilter: ColorFilter.mode(_statusColor, BlendMode.srcIn),
        ),
      ),
    );
  }

  Widget _nodeTapTarget(
    Size size,
    Offset frac,
    double radius,
    TopoNode node,
    String label,
    VoidCallback onTap,
  ) {
    final center = TopoLayout.resolve(size, frac);
    final d = (radius + 10) * 2;
    return Positioned(
      left: center.dx - d / 2,
      top: center.dy - d / 2,
      width: d,
      height: d,
      child: Semantics(
        label: label,
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressedNode = node),
          onTapCancel: () => setState(() => _pressedNode = null),
          onTapUp: (_) => setState(() => _pressedNode = null),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: GestureDetector(
        onTap: () => setState(() => _relativeTime = !_relativeTime),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Icon(Icons.history_toggle_off_rounded, color: TopoColors.textFaint, size: 14),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LAST KNOCK',
                    style: TextStyle(
                        color: TopoColors.textFaint, fontSize: 10, letterSpacing: 0.6, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(_lastKnockLabel,
                    style: TextStyle(color: TopoColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
