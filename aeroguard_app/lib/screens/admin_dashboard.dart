import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';
import '../config/transitions.dart';
import '../services/auth_service.dart';
import '../services/enclave_service.dart';
import '../services/notification_service.dart';
import '../widgets/live_telemetry_panel.dart';
import '../services/network_service.dart';
import 'sign_in_page.dart';
import 'device_identity_screen.dart';
import 'provision_token_screen.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  final _overviewKey = GlobalKey<_OverviewTabState>();

  late AnimationController _tabCtrl;
  late Animation<double>   _tabFade;

  @override
  void initState() {
    super.initState();
    _tabCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _tabFade = CurvedAnimation(parent: _tabCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _switchTab(int i) async {
    if (i == _index) return;
    await _tabCtrl.reverse();
    if (mounted) setState(() => _index = i);
    _tabCtrl.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050810),
      body: FadeTransition(
        opacity: _tabFade,
        child: IndexedStack(
          index: _index,
          children: [
            _OverviewTab(key: _overviewKey, onLogout: _logout),
            const _AccessTab(),
            _VaultTab(onVendorRevoked: () => _overviewKey.currentState?._fetchStats()),
          ],
        ),
      ),
      bottomNavigationBar: _BottomNav(
        currentIndex: _index,
        onTap: _switchTab,
      ),
    );
  }

  void _logout() async {
    await AuthService.logout();
    if (mounted) {
      Navigator.pushReplacement(context, fadeRoute(const SignInPage()));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOTTOM NAV
// ─────────────────────────────────────────────────────────────────────────────
class _BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNav({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF080E1A),
        border: Border(
          top: BorderSide(
            color: const Color(0xFF00C3FF).withValues(alpha: 0.08),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              _NavItem(
                icon: Icons.grid_view_rounded,
                label: 'OVERVIEW',
                index: 0,
                current: currentIndex,
                onTap: onTap,
              ),
              _NavItem(
                icon: Icons.shield_outlined,
                label: 'ACCESS',
                index: 1,
                current: currentIndex,
                onTap: onTap,
              ),
              _NavItem(
                icon: Icons.fingerprint,
                label: 'VAULT',
                index: 2,
                current: currentIndex,
                onTap: onTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final int index;
  final int current;
  final ValueChanged<int> onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = index == current;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xFF00C3FF).withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 20,
                color: active
                    ? const Color(0xFF00C3FF)
                    : const Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active
                    ? const Color(0xFF00C3FF)
                    : const Color(0xFF475569),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 1 — OVERVIEW
// ─────────────────────────────────────────────────────────────────────────────
class _OverviewTab extends StatefulWidget {
  final VoidCallback onLogout;
  const _OverviewTab({super.key, required this.onLogout});

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  Timer? _timer;
  String _username       = 'ADMIN';
  bool   _loadingStats   = true;
  bool   _statsError     = false;
  String _registeredAdmins    = '0';
  String _activeVendors       = '0';
  String _totalKnocks         = '0';
  String _gatewayStatus       = '—';
  List<String> _registeredAdminNames = [];
  List<String> _vendorNames          = [];

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _fetchStats();
    // Refresh stats every 30 seconds
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchStats());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadUsername() async {
    final u = await AuthService.getUsername();
    if (mounted && u != null) setState(() => _username = u.toUpperCase());
  }

  Future<void> _fetchStats() async {
    try {
      final response = await http
          .get(Uri.parse(ApiConstants.dashboardStatsEndpoint))
          .timeout(const Duration(seconds: 25));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _registeredAdmins     = '${data['registered_admins'] ?? data['active_admins'] ?? 0}';
          _activeVendors        = '${data['active_vendors']  ?? 0}';
          _totalKnocks          = '${data['total_knocks_today'] ?? 0}';
          _gatewayStatus        = data['gateway_status'] ?? 'SECURED';
          _registeredAdminNames = List<String>.from(data['registered_admin_names'] ?? data['admin_names'] ?? []);
          _vendorNames          = List<String>.from(data['vendor_names'] ?? []);
          _loadingStats  = false;
          _statsError    = false;
        });
      } else {
        if (mounted) setState(() { _statsError = true; _loadingStats = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _statsError = true; _loadingStats = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF050810), Color(0xFF0A1628)],
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // App bar
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'COMMAND CENTER',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'ADMIN  ·  $_username',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.3),
                          fontSize: 10,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onLogout,
                    icon: const Icon(
                      Icons.power_settings_new,
                      color: Color(0xFF475569),
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    _GatewayStatusCard(),
                    const SizedBox(height: 14),
                    const _PendingDevicePanel(),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.25,
                      children: [
                        _MetricCard(
                          label: 'ACTIVE ADMINS',
                          value: _registeredAdmins,
                          icon: Icons.person_outline_rounded,
                          names: _registeredAdminNames,
                          isLoading: _loadingStats,
                          accentColor: const Color(0xFF00C3FF),
                        ),
                        _MetricCard(
                          label: 'ACTIVE VENDORS',
                          value: _activeVendors,
                          icon: Icons.people_outline_rounded,
                          names: _vendorNames,
                          isLoading: _loadingStats,
                          accentColor: Colors.orangeAccent,
                        ),
                        _MetricCard(
                          label: 'KNOCKS TODAY',
                          value: _totalKnocks,
                          icon: Icons.data_usage_outlined,
                          isLoading: _loadingStats,
                          accentColor: const Color(0xFF818CF8),
                        ),
                        _MetricCard(
                          label: 'GATEWAY',
                          value: _statsError ? 'ERR' : _gatewayStatus,
                          icon: Icons.shield_outlined,
                          isLoading: _loadingStats,
                          accentColor: _statsError
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF10B981),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const LiveTelemetryPanel(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GatewayStatusCard extends StatefulWidget {
  const _GatewayStatusCard();

  @override
  State<_GatewayStatusCard> createState() => _GatewayStatusCardState();
}

class _GatewayStatusCardState extends State<_GatewayStatusCard>
    with SingleTickerProviderStateMixin {
  Timer? _gwTimer;
  Timer? _threatTimer;
  bool? _online;
  bool? _secured;

  int     _threatCount    = 0;
  String? _lastThreatIp;
  String? _lastThreatType;
  DateTime? _lastThreatAt;

  late AnimationController _glowCtrl;
  late Animation<double>   _glowAnim;

  bool get _isThreat =>
      _online == true &&
      _threatCount > 0 &&
      _lastThreatAt != null &&
      DateTime.now().difference(_lastThreatAt!).inSeconds < 120;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _glowAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );
    _checkGateway();
    _checkThreats();
    _gwTimer     = Timer.periodic(const Duration(seconds: 20), (_) => _checkGateway());
    _threatTimer = Timer.periodic(const Duration(seconds: 8),  (_) => _checkThreats());
  }

  @override
  void dispose() {
    _gwTimer?.cancel();
    _threatTimer?.cancel();
    _glowCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkGateway() async {
    bool online = false;
    try {
      final res = await http
          .get(Uri.parse(ApiConstants.gatewayHealthUrl))
          .timeout(const Duration(seconds: 4));
      online = res.statusCode == 200;
    } catch (_) {
      online = false;
    }

    bool? secured;
    if (online) {
      try {
        final socket = await Socket.connect(
          ApiConstants.gatewayIp, 9999,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
        secured = false;
      } on SocketException catch (e) {
        final code = e.osError?.errorCode;
        secured = (code == 111 || e.message.toLowerCase().contains('refused'))
            ? false
            : true;
      } catch (_) {
        secured = true;
      }
    }

    if (mounted) setState(() { _online = online; _secured = secured; });
  }

  Future<void> _checkThreats() async {
    try {
      final res = await http
          .get(Uri.parse(ApiConstants.gatewayThreatsEndpoint))
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final count = (data['recent_count'] as int?) ?? 0;
        DateTime? lastAt;
        final lastAtStr = data['last_threat_at'] as String?;
        if (lastAtStr != null) {
          try { lastAt = DateTime.parse(lastAtStr).toLocal(); } catch (_) {}
        }
        setState(() {
          _threatCount   = count;
          _lastThreatAt  = lastAt;
          _lastThreatIp  = data['last_threat_ip']   as String?;
          _lastThreatType = data['last_threat_type'] as String?;
        });
        if (_isThreat && !_glowCtrl.isAnimating) {
          _glowCtrl.repeat(reverse: true);
        } else if (!_isThreat && _glowCtrl.isAnimating) {
          _glowCtrl.stop();
          _glowCtrl.reset();
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final bool checking  = _online == null;
    final bool isOffline = _online == false;
    final bool isThreat  = !checking && !isOffline && _isThreat;

    Color  accent;
    String title, subtitle, badge;

    if (checking) {
      accent   = const Color(0xFF00C3FF);
      title    = 'GATEWAY';
      subtitle = 'Checking...';
      badge    = '···';
    } else if (isOffline) {
      accent   = const Color(0xFFEAB308); // yellow
      title    = 'GATEWAY OFFLINE';
      subtitle = 'Not reachable';
      badge    = 'OFFLINE';
    } else if (isThreat) {
      accent   = const Color(0xFFEF4444); // red
      title    = 'THREAT DETECTED';
      final reason = _lastThreatType?.replaceFirst('DENIED - ', '') ?? 'Unauthorized attempt';
      subtitle = '$reason · ${_lastThreatIp ?? 'unknown'}';
      badge    = 'THREAT';
    } else if (_secured == false) {
      accent   = const Color(0xFFF59E0B); // amber
      title    = 'GATEWAY UNSECURED';
      subtitle = 'Dark mode inactive';
      badge    = 'UNSECURED';
    } else {
      accent   = const Color(0xFF10B981); // green
      title    = 'GATEWAY SECURED';
      subtitle = 'Zero Trust enforced';
      badge    = 'ONLINE';
    }

    return AnimatedBuilder(
      animation: _glowAnim,
      builder: (context, child) {
        final g = isThreat ? _glowAnim.value : 0.0;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1421),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: accent.withValues(alpha: 0.40 + g * 0.35),
              width: isThreat ? 1.5 : 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.18 + g * 0.28),
                blurRadius: 32 + g * 28,
                spreadRadius: -2 + g * 5,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Row(
        children: [
          checking
              ? const SizedBox(
                  width: 8, height: 8,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00C3FF)),
                  ),
                )
              : _PulsingDot(color: _isThreat ? const Color(0xFFEF4444) :
                  isOffline ? const Color(0xFFEAB308) :
                  _secured == true ? const Color(0xFF10B981) : const Color(0xFFF59E0B)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    title,
                    key: ValueKey(title),
                    style: TextStyle(
                      color: _isThreat ? const Color(0xFFEF4444) :
                          isOffline ? const Color(0xFFEAB308) :
                          _secured == true ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.0,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    subtitle,
                    key: ValueKey(subtitle),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: (_isThreat ? const Color(0xFFEF4444) :
                  isOffline ? const Color(0xFFEAB308) :
                  _secured == true ? const Color(0xFF10B981) : const Color(0xFFF59E0B))
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              badge,
              style: TextStyle(
                color: _isThreat ? const Color(0xFFEF4444) :
                    isOffline ? const Color(0xFFEAB308) :
                    _secured == true ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final List<String> names;
  final bool isLoading;
  final Color accentColor;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.names = const [],
    this.isLoading = false,
    this.accentColor = const Color(0xFF00C3FF),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1B2E), Color(0xFF080F1C)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.28),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.10),
            blurRadius: 20,
            spreadRadius: -2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon badge — top-left with accent border
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: accentColor.withValues(alpha: 0.28),
                width: 0.8,
              ),
            ),
            child: Icon(
              icon,
              color: accentColor.withValues(alpha: 0.95),
              size: 14,
            ),
          ),
          const Spacer(),
          // Fixed-height value box — key fix for consistent alignment across all cards
          SizedBox(
            height: 32,
            child: isLoading
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                      ),
                    ),
                  )
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        height: 1.0,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF475569),
              fontSize: 9,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          // Fixed-height names row — prevents layout difference between cards
          SizedBox(
            height: 14,
            child: !isLoading && names.isNotEmpty
                ? Text(
                    names.join('  ·  '),
                    style: TextStyle(
                      color: accentColor.withValues(alpha: 0.85),
                      fontSize: 9,
                      letterSpacing: 0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 2 — ACCESS
// ─────────────────────────────────────────────────────────────────────────────
enum _KnockStatus { idle, knocking, success, failed }

class _AccessTab extends StatefulWidget {
  const _AccessTab();

  @override
  State<_AccessTab> createState() => _AccessTabState();
}

class _AccessTabState extends State<_AccessTab>
    with SingleTickerProviderStateMixin {
  _KnockStatus _knockStatus = _KnockStatus.idle;
  String _tunnelLabel = 'Standby — Awaiting knock';
  String _username    = '';
  Timer? _gatewayPollTimer;

  late AnimationController _headerCtrl;
  late Animation<double> _headerFade;
  late Animation<Offset> _headerSlide;

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _headerCtrl = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    )..forward();
    _headerFade = CurvedAnimation(parent: _headerCtrl, curve: Curves.easeOut);
    _headerSlide = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _headerCtrl, curve: Curves.easeOutCubic));
  }

  Future<void> _loadUsername() async {
    final u = await AuthService.getUsername() ?? '';
    if (mounted) setState(() => _username = u);
  }

  /// Polls gateway health every 12s while connected.
  /// Resets to idle automatically if the gateway goes offline.
  void _startGatewayPolling() {
    _gatewayPollTimer?.cancel();
    _gatewayPollTimer = Timer.periodic(const Duration(seconds: 12), (_) async {
      if (_knockStatus != _KnockStatus.success) {
        _gatewayPollTimer?.cancel();
        return;
      }
      bool online = false;
      try {
        final res = await http
            .get(Uri.parse(ApiConstants.gatewayHealthUrl))
            .timeout(const Duration(seconds: 4));
        online = res.statusCode == 200;
      } catch (_) {
        online = false;
      }
      if (!online && mounted && _knockStatus == _KnockStatus.success) {
        _gatewayPollTimer?.cancel();
        setState(() {
          _knockStatus = _KnockStatus.idle;
          _tunnelLabel = 'Gateway offline — session ended';
        });
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) setState(() => _tunnelLabel = 'Standby — Awaiting knock');
      }
    });
  }

  @override
  void dispose() {
    _headerCtrl.dispose();
    _gatewayPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleKnock() async {
    // Second tap while connected → terminate session on gateway
    if (_knockStatus == _KnockStatus.success) {
      _gatewayPollTimer?.cancel();
      setState(() {
        _knockStatus = _KnockStatus.idle;
        _tunnelLabel = 'Terminating session...';
      });
      await NetworkService.revokeAdminSession(_username);
      if (mounted) {
        setState(() => _tunnelLabel = 'Gateway closed — tunnel terminated');
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) setState(() => _tunnelLabel = 'Standby — Awaiting knock');
      }
      return;
    }

    setState(() {
      _knockStatus = _KnockStatus.knocking;
      _tunnelLabel = 'Establishing secure tunnel...';
    });

    final username = _username.isNotEmpty
        ? _username
        : (await AuthService.getUsername() ?? 'unknown');
    final success = await NetworkService.sendAuthorizationKnock(username);
    if (!mounted) return;

    if (success) {
      setState(() {
        _knockStatus = _KnockStatus.success;
        _tunnelLabel = 'Tunnel active — Connection secured';
      });
      _startGatewayPolling();
    } else {
      setState(() {
        _knockStatus = _KnockStatus.failed;
        _tunnelLabel = 'Connection refused — Check gateway';
      });
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) {
        setState(() {
          _knockStatus = _KnockStatus.idle;
          _tunnelLabel = 'Standby — Awaiting knock';
        });
      }
    }
  }

  Color get _statusColor => switch (_knockStatus) {
    _KnockStatus.success => const Color(0xFF10B981),
    _KnockStatus.failed => const Color(0xFFEF4444),
    _ => const Color(0xFF00C3FF),
  };

  IconData get _tunnelIcon => switch (_knockStatus) {
    _KnockStatus.success => Icons.wifi_tethering,
    _KnockStatus.failed => Icons.wifi_tethering_error,
    _ => Icons.wifi_tethering_outlined,
  };

  String get _knockLabel => switch (_knockStatus) {
    _KnockStatus.idle    => 'TAP TO INITIATE KNOCK',
    _KnockStatus.knocking => 'ESTABLISHING TUNNEL...',
    _KnockStatus.success => 'GATEWAY ACTIVE  ·  TAP TO CLOSE',
    _KnockStatus.failed  => 'ACCESS DENIED',
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF050810), Color(0xFF0A1628)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 18),
              FadeTransition(
                opacity: _headerFade,
                child: SlideTransition(
                  position: _headerSlide,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 26,
                        width: 26,
                        child: SvgPicture.asset(
                          'assets/images/Colored Logo.svg',
                          fit: BoxFit.contain,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'AEROGUARD',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // ── Tunnel status card ──────────────────────────────
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1421),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _statusColor.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(_tunnelIcon, color: _statusColor, size: 16),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'TUNNEL STATUS',
                          style: TextStyle(
                            color: Color(0xFF475569),
                            fontSize: 9,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            _tunnelLabel,
                            key: ValueKey(_tunnelLabel),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ── Central knock button ────────────────────────────
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _KnockButton(
                        status: _knockStatus,
                        onTap: _knockStatus == _KnockStatus.knocking
                            ? null
                            : _handleKnock,
                      ),
                      const SizedBox(height: 22),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _knockLabel,
                          key: ValueKey(_knockStatus),
                          style: TextStyle(
                            color: _statusColor.withValues(alpha: 0.75),
                            fontSize: 11,
                            letterSpacing: 2.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Provision vendor token ──────────────────────────
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  slideUpRoute(const ProvisionTokenScreen()),
                ),
                child: Container(
                  width: double.infinity,
                  height: 54,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.orangeAccent.withValues(alpha: 0.3),
                    ),
                    color: Colors.orangeAccent.withValues(alpha: 0.04),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code, color: Colors.orangeAccent, size: 16),
                      SizedBox(width: 10),
                      Text(
                        'PROVISION VENDOR TOKEN',
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2.0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KNOCK BUTTON
// ─────────────────────────────────────────────────────────────────────────────
class _KnockButton extends StatefulWidget {
  final _KnockStatus status;
  final VoidCallback? onTap;

  const _KnockButton({required this.status, required this.onTap});

  @override
  State<_KnockButton> createState() => _KnockButtonState();
}

class _KnockButtonState extends State<_KnockButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);
    _pulse = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (widget.status) {
      _KnockStatus.success => const Color(0xFF10B981),
      _KnockStatus.failed => const Color(0xFFEF4444),
      _ => const Color(0xFF00C3FF),
    };

    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => SizedBox(
          height: 216,
          width: 216,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Ring 3 — outermost, very faint
              Container(
                height: 200 + _pulse.value * 10,
                width: 200 + _pulse.value * 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.07 + _pulse.value * 0.04),
                    width: 1,
                  ),
                ),
              ),
              // Ring 2
              Container(
                height: 162 + _pulse.value * 7,
                width: 162 + _pulse.value * 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.13 + _pulse.value * 0.09),
                    width: 1,
                  ),
                ),
              ),
              // Ring 1 — closest, with glow
              Container(
                height: 124 + _pulse.value * 4,
                width: 124 + _pulse.value * 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(alpha: 0.2 + _pulse.value * 0.14),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(
                        alpha: 0.05 + _pulse.value * 0.07,
                      ),
                      blurRadius: 24,
                      spreadRadius: 3,
                    ),
                  ],
                ),
              ),
              // Center button
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                height: 112,
                width: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.3, -0.3),
                    radius: 1,
                    colors: [
                      color.withValues(alpha: 0.28),
                      color.withValues(alpha: 0.08),
                    ],
                  ),
                  border: Border.all(
                    color: color.withValues(alpha: 0.7),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(
                        alpha: 0.22 + _pulse.value * 0.14,
                      ),
                      blurRadius: 32,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        'assets/images/Light Logo.svg',
                        height: 32,
                        width: 32,
                        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        switch (widget.status) {
                          _KnockStatus.success => 'GATEWAY\nOPEN',
                          _KnockStatus.failed => 'ACCESS\nDENIED',
                          _ => 'INITIATE\nKNOCK',
                        },
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: color,
                          fontSize: 7.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          height: 1.5,
                        ),
                      ),
                      if (widget.status == _KnockStatus.knocking) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 26,
                          width: 26,
                          child: CircularProgressIndicator(
                            color: color,
                            strokeWidth: 2,
                          ),
                        ),
                      ],
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
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 3 — VAULT
// ─────────────────────────────────────────────────────────────────────────────
class _VaultTab extends StatefulWidget {
  final VoidCallback? onVendorRevoked;
  const _VaultTab({this.onVendorRevoked});

  @override
  State<_VaultTab> createState() => _VaultTabState();
}

class _VaultTabState extends State<_VaultTab> {
  Timer?  _timer;
  bool    _loading     = true;
  bool    _error       = false;
  String  _deviceId    = '—';
  String? _lastKnockAt;
  List<Map<String, dynamic>> _sessions = [];

  @override
  void initState() {
    super.initState();
    _loadDeviceId();
    _fetchVaultData();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchVaultData());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadDeviceId() async {
    final id = await EnclaveService.getDeviceId();
    if (mounted) setState(() => _deviceId = id);
  }

  Future<void> _fetchVaultData() async {
    try {
      final res = await http
          .get(Uri.parse(ApiConstants.vendorSessionsEndpoint))
          .timeout(const Duration(seconds: 25));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _sessions    = List<Map<String, dynamic>>.from(data['sessions'] ?? []);
          _lastKnockAt = data['last_knock_at'] as String?;
          _loading     = false;
          _error       = false;
        });
      } else {
        if (mounted) setState(() { _error = true; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _error = true; _loading = false; });
    }
  }

  Future<void> _revokeVendor(Map<String, dynamic> session) async {
    final vendorUsername = session['vendor_username']?.toString() ?? '—';
    final company        = session['company_name']?.toString()    ?? vendorUsername;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1421),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('REVOKE SESSION?',
            style: TextStyle(color: Color(0xFFEF4444), fontSize: 14, letterSpacing: 2.0, fontWeight: FontWeight.bold)),
        content: Text(
          'Terminate the active tunnel for $company? This will immediately cut their network access.',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL', style: TextStyle(color: Color(0xFF475569), letterSpacing: 1.0)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('REVOKE', style: TextStyle(color: Color(0xFFEF4444), letterSpacing: 1.0, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final adminUsername = await AuthService.getUsername() ?? 'admin';
      final res = await http.post(
        Uri.parse(ApiConstants.revokeVendorEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'admin_username': adminUsername, 'vendor_username': vendorUsername}),
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;
      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$company session revoked.',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ));
        _fetchVaultData();
        widget.onVendorRevoked?.call();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Revoke failed — check connection.',
              style: TextStyle(color: Colors.white, fontSize: 13)),
          backgroundColor: const Color(0xFF334155),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
        ));
      }
    }
  }

  String _timeRemaining(String? validUntil) {
    if (validUntil == null) return '—';
    try {
      final expiry    = DateTime.parse(validUntil).toUtc();
      final remaining = expiry.difference(DateTime.now().toUtc());
      if (remaining.isNegative) return 'EXPIRED';
      if (remaining.inHours > 0) {
        return '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m remaining';
      }
      return '${remaining.inMinutes}m ${remaining.inSeconds.remainder(60)}s remaining';
    } catch (_) {
      return '—';
    }
  }

  String _formatTimestamp(String? iso) {
    if (iso == null) return 'No events recorded';
    try {
      final dt = DateTime.parse(iso).toLocal();
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '${months[dt.month - 1]} ${dt.day}  ·  $h:$m';
    } catch (_) {
      return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF050810), Color(0xFF0A1628)],
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              const Text('HARDWARE VAULT',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              const SizedBox(height: 4),
              Text('Device identity & active sessions',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 12)),
              const SizedBox(height: 20),

              // ── Secure Enclave ──────────────────────────────────────────
              _card(
                borderColor: const Color(0xFF00C3FF).withValues(alpha: 0.1),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    _iconBox(Icons.memory, const Color(0xFF00C3FF)),
                    const SizedBox(width: 14),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('SECURE ENCLAVE',
                          style: TextStyle(color: Color(0xFF475569), fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(_deviceId,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                  ]),
                  Divider(color: Colors.white.withValues(alpha: 0.05), height: 24),
                  Text('ECDSA P-256 key pair locked in hardware vault.',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11, height: 1.5)),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => Navigator.push(context, slideUpRoute(const DeviceIdentityScreen())),
                    child: _outlineBtn('VIEW FULL IDENTITY', Icons.vpn_key_outlined, const Color(0xFF00C3FF)),
                  ),
                ]),
              ),

              const SizedBox(height: 12),

              // ── Last knock event ────────────────────────────────────────
              _card(
                borderColor: const Color(0xFF00C3FF).withValues(alpha: 0.08),
                child: Row(children: [
                  _iconBox(Icons.bolt_outlined, const Color(0xFF00C3FF)),
                  const SizedBox(width: 14),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('LAST KNOCK EVENT',
                        style: TextStyle(color: Color(0xFF475569), fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    _loading
                        ? const SizedBox(height: 14, width: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5,
                                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00C3FF))))
                        : Text(_formatTimestamp(_lastKnockAt),
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ),

              const SizedBox(height: 12),

              // ── Active vendor sessions ──────────────────────────────────
              _card(
                borderColor: Colors.orangeAccent.withValues(alpha: 0.15),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    _iconBox(Icons.people_outline_rounded, Colors.orangeAccent),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text('ACTIVE VENDOR SESSIONS',
                          style: TextStyle(color: Color(0xFF475569), fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                    ),
                    if (!_loading)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('${_sessions.length}',
                            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                  ]),
                  Divider(color: Colors.white.withValues(alpha: 0.05), height: 20),
                  if (_loading)
                    const Center(child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: SizedBox(height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 1.5,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.orangeAccent))),
                    ))
                  else if (_error)
                    Row(children: [
                      Icon(Icons.wifi_off_outlined,
                          color: const Color(0xFFEF4444).withValues(alpha: 0.6), size: 15),
                      const SizedBox(width: 10),
                      const Text('Unable to load sessions.',
                          style: TextStyle(color: Color(0xFF475569), fontSize: 12)),
                    ])
                  else if (_sessions.isEmpty)
                    Row(children: [
                      Icon(Icons.check_circle_outline,
                          color: const Color(0xFF10B981).withValues(alpha: 0.6), size: 15),
                      const SizedBox(width: 10),
                      const Text('No active vendor sessions',
                          style: TextStyle(color: Color(0xFF475569), fontSize: 12)),
                    ])
                  else
                    ...List.generate(_sessions.length, (i) {
                      final s = _sessions[i];
                      return Column(children: [
                        _VendorSessionRow(
                          vendorUsername: s['vendor_username']?.toString() ?? '—',
                          company:        s['company_name']?.toString()    ?? '—',
                          clearance:      s['clearance_level']?.toString() ?? '—',
                          timeRemaining:  _timeRemaining(s['valid_until']?.toString()),
                          status:         s['status']?.toString()          ?? '—',
                          onRevoke: () => _revokeVendor(s),
                        ),
                        if (i < _sessions.length - 1)
                          Divider(color: Colors.white.withValues(alpha: 0.04), height: 16),
                      ]);
                    }),
                ]),
              ),

              const SizedBox(height: 12),

              // ── Security actions ────────────────────────────────────────
              _card(
                borderColor: Colors.white.withValues(alpha: 0.05),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('SECURITY ACTIONS',
                      style: TextStyle(color: Color(0xFF475569), fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  _VaultAction(
                    icon: Icons.qr_code,
                    label: 'Provision Vendor Token',
                    subtitle: 'Generate JIT QR access',
                    onTap: () => Navigator.push(context, slideUpRoute(const ProvisionTokenScreen())),
                  ),
                  Divider(color: Colors.white.withValues(alpha: 0.05), height: 20),
                  _VaultAction(
                    icon: Icons.delete_outline,
                    label: 'Revoke This Device',
                    subtitle: 'Destroy hardware keys',
                    color: const Color(0xFFEF4444),
                    onTap: () {},
                  ),
                ]),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card({required Widget child, required Color borderColor}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1421),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
        ),
        child: child,
      );

  Widget _iconBox(IconData icon, Color color) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 18),
      );

  Widget _outlineBtn(String label, IconData icon, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
          color: color.withValues(alpha: 0.05),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
        ]),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// VENDOR SESSION ROW
// ─────────────────────────────────────────────────────────────────────────────
class _VendorSessionRow extends StatelessWidget {
  final String vendorUsername;
  final String company;
  final String clearance;
  final String timeRemaining;
  final String status;
  final VoidCallback onRevoke;

  const _VendorSessionRow({
    required this.vendorUsername,
    required this.company,
    required this.clearance,
    required this.timeRemaining,
    required this.status,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = status == 'active';
    final dotColor = isActive ? const Color(0xFF10B981) : Colors.orangeAccent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              height: 7, width: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: dotColor,
                boxShadow: [BoxShadow(color: dotColor.withValues(alpha: 0.5), blurRadius: 6)],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(company,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('$vendorUsername  ·  ${clearance.toUpperCase()}',
                  style: const TextStyle(color: Color(0xFF475569), fontSize: 10, letterSpacing: 0.4)),
              const SizedBox(height: 5),
              Row(children: [
                Icon(Icons.timer_outlined,
                    color: Colors.orangeAccent.withValues(alpha: 0.7), size: 11),
                const SizedBox(width: 4),
                Text(timeRemaining,
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 10, letterSpacing: 0.3)),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onRevoke,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.35)),
              ),
              child: const Text('REVOKE',
                  style: TextStyle(color: Color(0xFFEF4444), fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            ),
          ),
        ],
      ),
    );
  }
}

class _VaultAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final Color color;

  const _VaultAction({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.color = const Color(0xFF94A3B8),
  });

  @override
  Widget build(BuildContext context) {
    final isDanger = color == const Color(0xFFEF4444);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Icon(icon, color: color.withValues(alpha: 0.7), size: 18),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                    color: isDanger ? const Color(0xFFEF4444) : Colors.white,
                    fontSize: 13, fontWeight: FontWeight.w500,
                  )),
              Text(subtitle,
                  style: const TextStyle(color: Color(0xFF475569), fontSize: 11)),
            ],
          ),
          const Spacer(),
          Icon(Icons.chevron_right,
              color: const Color(0xFF475569).withValues(alpha: 0.5), size: 18),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PENDING VENDOR DEVICE APPROVAL PANEL
// ─────────────────────────────────────────────────────────────────────────────
class _PendingDevicePanel extends StatefulWidget {
  const _PendingDevicePanel();

  @override
  State<_PendingDevicePanel> createState() => _PendingDevicePanelState();
}

class _PendingDevicePanelState extends State<_PendingDevicePanel> {
  Timer? _timer;
  List<Map<String, dynamic>> _pending = [];
  final Set<String> _seenTokens = {};

  @override
  void initState() {
    super.initState();
    NotificationService.init();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _fetch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final res = await http
          .get(Uri.parse(ApiConstants.pendingVendorDevicesEndpoint))
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final newList =
            List<Map<String, dynamic>>.from(data['pending'] ?? []);
        // Fire OS notification for newly detected pending devices
        for (final device in newList) {
          final token = device['qr_token'] as String? ?? '';
          if (token.isNotEmpty && !_seenTokens.contains(token)) {
            _seenTokens.add(token);
            NotificationService.showVendorDeviceAlert(
              vendorName: device['vendor_username'] as String? ?? '',
              company: device['company_name'] as String? ?? '',
              deviceIp: device['pending_device_ip'] as String? ?? '',
              deviceMac: device['pending_device_mac'] as String? ?? '',
            );
          }
        }
        setState(() => _pending = newList);
      }
    } catch (_) {}
  }

  Future<void> _action(String tokenHash, bool approved,
      [String? overrideIp, String? overrideMac]) async {
    final username = await AuthService.getUsername() ?? 'admin';
    try {
      final body = <String, dynamic>{
        'token_hash':     tokenHash,
        'admin_username': username,
        'approved':       approved,
      };
      if (overrideIp  != null) body['override_ip']  = overrideIp;
      if (overrideMac != null) body['override_mac'] = overrideMac;
      await http
          .post(
            Uri.parse(ApiConstants.approveVendorDeviceEndpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
    await _fetch();
  }

  @override
  Widget build(BuildContext context) {
    if (_pending.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _PulsingDot(color: Colors.orangeAccent),
            const SizedBox(width: 8),
            const Text(
              'DEVICE APPROVAL REQUIRED',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final device in _pending) ...[
          _PendingDeviceCard(
            vendorName: device['vendor_username'] as String? ?? '—',
            company: device['company_name'] as String? ?? '—',
            deviceIp: device['pending_device_ip'] as String? ?? '—',
            deviceMac: device['pending_device_mac'] as String? ?? '—',
            tokenHash: device['qr_token'] as String? ?? '',
            onAction: _action,
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 4),
      ],
    );
  }
}

class _PendingDeviceCard extends StatefulWidget {
  final String vendorName;
  final String company;
  final String deviceIp;
  final String deviceMac;
  final String tokenHash;
  final Future<void> Function(String token, bool approved,
      [String? overrideIp, String? overrideMac]) onAction;

  const _PendingDeviceCard({
    required this.vendorName,
    required this.company,
    required this.deviceIp,
    required this.deviceMac,
    required this.tokenHash,
    required this.onAction,
  });

  @override
  State<_PendingDeviceCard> createState() => _PendingDeviceCardState();
}

class _PendingDeviceCardState extends State<_PendingDeviceCard> {
  bool    _processing  = false;
  String? _overrideIp;
  String? _overrideMac;

  Future<void> _handle(bool approved) async {
    setState(() => _processing = true);
    await widget.onAction(widget.tokenHash, approved, _overrideIp, _overrideMac);
    if (mounted) setState(() => _processing = false);
  }

  Future<void> _scanNetwork() async {
    final picked = await showModalBottomSheet<Map<String, String>>(
      context: context,
      backgroundColor: const Color(0xFF0D1421),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (_) => const _NetworkScanSheet(),
    );
    if (picked != null && mounted) {
      setState(() {
        _overrideIp  = picked['ip'];
        _overrideMac = picked['mac'];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1008), Color(0xFF0D1421)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.orangeAccent.withValues(alpha: 0.45),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.orangeAccent.withValues(alpha: 0.12),
            blurRadius: 24,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: vendor info + pulsing dot
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.orangeAccent.withValues(alpha: 0.3),
                    width: 0.8,
                  ),
                ),
                child: const Icon(
                  Icons.devices_other_rounded,
                  color: Colors.orangeAccent,
                  size: 16,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.vendorName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      widget.company,
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _PulsingDot(color: Colors.orangeAccent),
            ],
          ),
          const SizedBox(height: 14),
          // Device info — shows override selection if admin picked from scan
          Row(
            children: [
              _DeviceInfoChip(label: 'IP',  value: _overrideIp  ?? widget.deviceIp),
              const SizedBox(width: 8),
              Expanded(
                child: _DeviceInfoChip(label: 'MAC', value: _overrideMac ?? widget.deviceMac),
              ),
            ],
          ),
          if (_overrideIp != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                'OVERRIDE SELECTED',
                style: TextStyle(
                  color: Colors.cyanAccent.withValues(alpha: 0.75),
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          const SizedBox(height: 10),
          // Scan network button
          GestureDetector(
            onTap: _scanNetwork,
            child: Container(
              width: double.infinity,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.25)),
              ),
              child: const Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_find_rounded, color: Colors.cyanAccent, size: 13),
                    SizedBox(width: 6),
                    Text(
                      'SCAN NETWORK',
                      style: TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Deny / Approve buttons
          _processing
              ? const Center(
                  child: SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.orangeAccent),
                    ),
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _handle(false),
                        child: Container(
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFFEF4444).withValues(alpha: 0.40),
                            ),
                          ),
                          child: const Center(
                            child: Text(
                              'DENY',
                              style: TextStyle(
                                color: Color(0xFFEF4444),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _handle(true),
                        child: Container(
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFF10B981).withValues(alpha: 0.45),
                            ),
                          ),
                          child: const Center(
                            child: Text(
                              'APPROVE',
                              style: TextStyle(
                                color: Color(0xFF10B981),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.0,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NETWORK SCAN BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────────────
class _NetworkScanSheet extends StatefulWidget {
  const _NetworkScanSheet();

  @override
  State<_NetworkScanSheet> createState() => _NetworkScanSheetState();
}

class _NetworkScanSheetState extends State<_NetworkScanSheet> {
  bool   _loading = true;
  String? _error;
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http
          .get(Uri.parse(ApiConstants.networkScanEndpoint))
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _devices = List<Map<String, dynamic>>.from(data['devices'] ?? []);
          _loading = false;
        });
      } else {
        setState(() { _error = 'Scan failed (${res.statusCode})'; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _error = 'Gateway unreachable'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.wifi_find_rounded, color: Colors.cyanAccent, size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'NETWORK DEVICES',
                    style: TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.0,
                    ),
                  ),
                ),
                if (!_loading)
                  GestureDetector(
                    onTap: _scan,
                    child: const Icon(Icons.refresh_rounded,
                        color: Color(0xFF64748B), size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap a device to select it as the vendor laptop',
              style: TextStyle(color: Color(0xFF475569), fontSize: 11),
            ),
            const SizedBox(height: 14),
            Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
            const SizedBox(height: 12),
            // Content
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                      ),
                      SizedBox(height: 12),
                      Text('Scanning subnet...',
                          style: TextStyle(
                              color: Color(0xFF64748B), fontSize: 12)),
                    ],
                  ),
                ),
              )
            else if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: Color(0xFFEF4444), fontSize: 12)),
                ),
              )
            else if (_devices.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No devices found — try refreshing',
                      style: TextStyle(
                          color: Color(0xFF64748B), fontSize: 12)),
                ),
              )
            else
              ...(_devices.map((d) {
                final ip  = d['ip']  as String? ?? '—';
                final mac = d['mac'] as String? ?? '—';
                return GestureDetector(
                  onTap: () =>
                      Navigator.pop(context, {'ip': ip, 'mac': mac}),
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.cyanAccent.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.cyanAccent.withValues(alpha: 0.15)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.computer_rounded,
                            color: Color(0xFF64748B), size: 14),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(ip,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5)),
                              const SizedBox(height: 2),
                              Text(mac,
                                  style: const TextStyle(
                                      color: Color(0xFF64748B),
                                      fontSize: 10,
                                      letterSpacing: 0.5)),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded,
                            color: Color(0xFF334155), size: 12),
                      ],
                    ),
                  ),
                );
              }).toList()),
          ],
        ),
      ),
    );
  }
}

class _DeviceInfoChip extends StatelessWidget {
  final String label;
  final String value;

  const _DeviceInfoChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1421),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.orangeAccent.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label  ',
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED — PULSING DOT
// ─────────────────────────────────────────────────────────────────────────────
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.55,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: _anim.value),
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: _anim.value * 0.7),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
      ),
    );
  }
}
