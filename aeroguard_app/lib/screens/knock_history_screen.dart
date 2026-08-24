import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/api_constants.dart';
import '../config/theme.dart';

// ── Tuning ──────────────────────────────────────────────────────────────
// How often the feed re-polls the backend. Faster than the other dashboard
// panels (4-15s) since this is the app's dedicated "live feed" surface.
const int _pollSeconds = 5;
// How many hourly buckets the activity chart shows.
const int _chartHours = 8;

enum _ActorFilter { all, admin, vendor }

/// Combined, real-time admin + vendor knock history — a 4th dashboard tab
/// alongside Overview/Access/Vault. Polls the same way every other panel in
/// this dashboard does (Timer + plain http, see admin_dashboard.dart) rather
/// than introducing a new transport just for this screen.
class KnockHistoryTab extends StatefulWidget {
  const KnockHistoryTab({super.key});

  @override
  State<KnockHistoryTab> createState() => _KnockHistoryTabState();
}

class _KnockHistoryTabState extends State<KnockHistoryTab> {
  Timer? _timer;
  List<Map<String, dynamic>> _knocks = [];
  Set<int> _newIds = {}; // ids that just appeared this poll — get the reveal animation
  final Set<int> _seenIds = {};
  bool _firstLoad = true;
  bool _loading = true;
  bool _error = false;
  int _grantedCount = 0;
  int _deniedCount = 0;
  _ActorFilter _filter = _ActorFilter.all;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: _pollSeconds), (_) => _fetch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final res = await http
          .get(Uri.parse(ApiConstants.knockHistoryEndpoint))
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = List<Map<String, dynamic>>.from(data['knocks'] ?? []);

        final newIds = <int>{};
        if (!_firstLoad) {
          for (final k in list) {
            final id = k['id'] as int?;
            if (id != null && !_seenIds.contains(id)) newIds.add(id);
          }
        }
        for (final k in list) {
          final id = k['id'] as int?;
          if (id != null) _seenIds.add(id);
        }

        setState(() {
          _knocks = list;
          _grantedCount = (data['granted_count'] as num?)?.toInt() ?? 0;
          _deniedCount = (data['denied_count'] as num?)?.toInt() ?? 0;
          _newIds = newIds;
          _loading = false;
          _error = false;
          _firstLoad = false;
        });
      } else {
        if (mounted) setState(() { _error = true; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _error = true; _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    switch (_filter) {
      case _ActorFilter.admin:
        return _knocks.where((k) => k['actor_type'] == 'admin').toList();
      case _ActorFilter.vendor:
        return _knocks.where((k) => k['actor_type'] == 'vendor').toList();
      case _ActorFilter.all:
        return _knocks;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceMuted,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'KNOCK HISTORY',
                        style: TextStyle(
                          color: AppColors.inkPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Admin & vendor access log',
                        style: TextStyle(color: AppColors.inkFaint, fontSize: 10, letterSpacing: 1.5),
                      ),
                    ],
                  ),
                  const Spacer(),
                  _LiveBadge(error: _error),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: _SummaryChip(
                      label: 'GRANTED',
                      value: _grantedCount,
                      color: const Color(0xFF10B981),
                      icon: Icons.check_circle_outline,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SummaryChip(
                      label: 'DENIED',
                      value: _deniedCount,
                      color: const Color(0xFFEF4444),
                      icon: Icons.block_outlined,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _ActivityChart(knocks: _knocks),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _FilterRow(
                filter: _filter,
                onChanged: (f) => setState(() => _filter = f),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildList(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_loading) {
      return Center(
        child: SizedBox(
          height: 26,
          width: 26,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandBlue),
          ),
        ),
      );
    }

    final filtered = _filtered;
    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _error ? Icons.wifi_off_outlined : Icons.history_toggle_off,
                color: AppColors.inkFaint,
                size: 28,
              ),
              const SizedBox(height: 12),
              Text(
                _error ? 'Unable to load history.' : 'No knock activity yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.inkFaint, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final items = _groupByDay(filtered);

    return RefreshIndicator(
      color: AppColors.brandBlue,
      backgroundColor: AppColors.surface,
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          if (item is String) {
            return Padding(
              padding: EdgeInsets.only(top: i == 0 ? 4 : 18, bottom: 8),
              child: Text(
                item,
                style: TextStyle(
                  color: AppColors.inkFaint,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                ),
              ),
            );
          }
          final knock = item as Map<String, dynamic>;
          final id = knock['id'] as int?;
          final row = _KnockRow(knock: knock);
          if (id != null && _newIds.contains(id)) {
            return _NewRowReveal(key: ValueKey(id), child: row);
          }
          return KeyedSubtree(key: ValueKey(id ?? knock.hashCode), child: row);
        },
      ),
    );
  }

  List<Object> _groupByDay(List<Map<String, dynamic>> knocks) {
    final items = <Object>[];
    String? lastLabel;
    for (final k in knocks) {
      final label = _dayLabel(k['created_at'] as String?);
      if (label != lastLabel) {
        items.add(label);
        lastLabel = label;
      }
      items.add(k);
    }
    return items;
  }
}

// Colombo local day, matching the timezone convention used elsewhere in
// this dashboard.
String _dayLabel(String? isoUtc) {
  if (isoUtc == null) return 'UNKNOWN';
  try {
    final dt = DateTime.parse(isoUtc).toUtc().add(const Duration(hours: 5, minutes: 30));
    final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'TODAY';
    if (diff == 1) return 'YESTERDAY';
    const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
    return '${months[dt.month - 1]} ${dt.day}';
  } catch (_) {
    return 'UNKNOWN';
  }
}

String _timeLabel(String? isoUtc) {
  if (isoUtc == null) return '—';
  try {
    final dt = DateTime.parse(isoUtc).toUtc().add(const Duration(hours: 5, minutes: 30));
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  } catch (_) {
    return '—';
  }
}

// ─────────────────────────────────────────────────────────────────────────
// LIVE BADGE
// ─────────────────────────────────────────────────────────────────────────
class _LiveBadge extends StatefulWidget {
  final bool error;
  const _LiveBadge({required this.error});

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1200), vsync: this)
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.5, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.error ? const Color(0xFFEF4444) : const Color(0xFF10B981);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _anim,
            builder: (context, _) => Container(
              height: 6,
              width: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: _anim.value),
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: _anim.value * 0.6), blurRadius: 6, spreadRadius: 1),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            widget.error ? 'OFFLINE' : 'LIVE',
            style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.5),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SUMMARY CHIP
// ─────────────────────────────────────────────────────────────────────────
class _SummaryChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final IconData icon;

  const _SummaryChip({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: AppColors.softShadow(tint: color, opacity: 0.08),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: TextStyle(color: AppColors.inkPrimary, fontSize: 20, fontWeight: FontWeight.w800, height: 1.0),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(color: AppColors.inkFaint, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.2),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// ACTIVITY CHART — granted (green) vs denied (red) knocks per hour, stacked
// bars anchored to a baseline. Single unfiltered dataset (the "big
// picture"), independent of the list's own actor filter below it.
// ─────────────────────────────────────────────────────────────────────────
class _ActivityChart extends StatelessWidget {
  final List<Map<String, dynamic>> knocks;
  const _ActivityChart({required this.knocks});

  List<_HourBucket> _buildBuckets() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final currentHour = DateTime(now.year, now.month, now.day, now.hour);
    final buckets = List.generate(
      _chartHours,
      (i) => _HourBucket(hour: currentHour.subtract(Duration(hours: _chartHours - 1 - i))),
    );

    for (final k in knocks) {
      final iso = k['created_at'] as String?;
      if (iso == null) continue;
      DateTime dt;
      try {
        dt = DateTime.parse(iso).toUtc().add(const Duration(hours: 5, minutes: 30));
      } catch (_) {
        continue;
      }
      final bucketHour = DateTime(dt.year, dt.month, dt.day, dt.hour);
      for (final b in buckets) {
        if (b.hour == bucketHour) {
          if (k['status'] == 'GRANTED') {
            b.granted++;
          } else {
            b.denied++;
          }
          break;
        }
      }
    }
    return buckets;
  }

  @override
  Widget build(BuildContext context) {
    final buckets = _buildBuckets();
    // Rounds the scale up to a clean reference value instead of the exact
    // busiest hour — a bar for the actual busiest hour would otherwise
    // always touch the very top with no headroom, and the gridline/count
    // label would land flush against the chart's edge.
    final rawMax = buckets.fold<int>(1, (m, b) => b.total > m ? b.total : m);
    final maxTotal = _niceCeiling(rawMax);
    final totalGranted = buckets.fold<int>(0, (s, b) => s + b.granted);
    final totalDenied = buckets.fold<int>(0, (s, b) => s + b.denied);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: AppColors.softShadow(opacity: 0.08),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ACTIVITY',
                    style: TextStyle(color: AppColors.inkPrimary, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.8),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Last $_chartHours hours · ${totalGranted + totalDenied} knocks',
                    style: TextStyle(color: AppColors.inkFaint, fontSize: 9.5, letterSpacing: 0.3),
                  ),
                ],
              ),
              const Spacer(),
              _LegendDot(color: const Color(0xFF10B981), label: 'Granted', count: totalGranted),
              const SizedBox(width: 14),
              _LegendDot(color: const Color(0xFFEF4444), label: 'Denied', count: totalDenied),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 148,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final b in buckets) ...[
                  Expanded(child: _Bar(bucket: b, maxTotal: maxTotal)),
                  if (b != buckets.last) const SizedBox(width: 7),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final b in buckets) ...[
                Expanded(
                  child: Text(
                    _hourLabel(b.hour.hour),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.inkFaint, fontSize: 8.5, fontWeight: FontWeight.w600),
                  ),
                ),
                if (b != buckets.last) const SizedBox(width: 7),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // 12h clock, matching the rest of the app's time-of-day convention —
  // plain "hour" digits alone don't say whether a bar is from this
  // morning or last night.
  static String _hourLabel(int hour24) {
    final h = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$h${hour24 < 12 ? 'a' : 'p'}';
  }

  // Rounds up to a clean-looking scale ceiling (1, 2, 5, 10, 20, 50, ...)
  // so the chart has visible headroom above the busiest bar instead of
  // that bar always pinning exactly to the top edge.
  static int _niceCeiling(int value) {
    if (value <= 1) return 1;
    for (final step in [2, 3, 5, 8, 10, 15, 20, 30, 50, 80, 100]) {
      if (value <= step) return step;
    }
    var ceiling = 100;
    while (ceiling < value) {
      ceiling *= 2;
    }
    return ceiling;
  }
}

class _HourBucket {
  final DateTime hour;
  int granted = 0;
  int denied = 0;
  _HourBucket({required this.hour});
  int get total => granted + denied;
}

class _Bar extends StatelessWidget {
  final _HourBucket bucket;
  final int maxTotal;
  const _Bar({required this.bucket, required this.maxTotal});

  // The visible track a bar can grow within — deliberately shorter than
  // the chart's full SizedBox height, leaving room above for the count
  // label so it never crowds the tallest bar.
  static const double trackHeight = 122;
  static const double minVisible = 4;

  @override
  Widget build(BuildContext context) {
    final grantedH = bucket.granted == 0 ? 0.0 : (bucket.granted / maxTotal) * trackHeight;
    final deniedH = bucket.denied == 0 ? 0.0 : (bucket.denied / maxTotal) * trackHeight;
    final grantedHeight = bucket.granted == 0 ? 0.0 : (grantedH < minVisible ? minVisible : grantedH);
    final deniedHeight = bucket.denied == 0 ? 0.0 : (deniedH < minVisible ? minVisible : deniedH);
    final hasBoth = bucket.granted > 0 && bucket.denied > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // Count label — reserves its row always, so every column's track
        // lines up at the same baseline regardless of whether that hour
        // had any activity.
        SizedBox(
          height: 15,
          child: bucket.total > 0
              ? Center(
                  child: Text(
                    '${bucket.total}',
                    style: TextStyle(color: AppColors.inkSecondary, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                )
              : null,
        ),
        const SizedBox(height: 5),
        // A constant full-height rail behind every bar — the actual scale
        // reference. Without it, a lone short bar has nothing to visually
        // compare itself against and low activity is easy to misread as
        // "about the same" as a busier hour instead of genuinely quiet.
        SizedBox(
          height: trackHeight,
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: AppColors.border.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (bucket.denied > 0)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutCubic,
                      height: deniedHeight,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.9),
                        borderRadius: BorderRadius.vertical(
                          top: const Radius.circular(5),
                          bottom: hasBoth ? Radius.zero : const Radius.circular(5),
                        ),
                      ),
                    ),
                  if (hasBoth) const SizedBox(height: 2), // surface gap between stacked segments
                  if (bucket.granted > 0)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 450),
                      curve: Curves.easeOutCubic,
                      height: grantedHeight,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF34D399), Color(0xFF0EA371)],
                        ),
                        borderRadius: BorderRadius.vertical(
                          top: hasBoth ? Radius.zero : const Radius.circular(5),
                          bottom: const Radius.circular(5),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final int count;
  const _LegendDot({required this.color, required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(height: 6, width: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(color: AppColors.inkSecondary, fontSize: 9, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 1),
        Text('$count', style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// FILTER ROW
// ─────────────────────────────────────────────────────────────────────────
class _FilterRow extends StatelessWidget {
  final _ActorFilter filter;
  final ValueChanged<_ActorFilter> onChanged;
  const _FilterRow({required this.filter, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _FilterChip(label: 'ALL', selected: filter == _ActorFilter.all, color: AppColors.brandBlue, onTap: () => onChanged(_ActorFilter.all)),
        const SizedBox(width: 8),
        _FilterChip(label: 'ADMIN', selected: filter == _ActorFilter.admin, color: AppColors.brandBlue, onTap: () => onChanged(_ActorFilter.admin)),
        const SizedBox(width: 8),
        _FilterChip(label: 'VENDOR', selected: filter == _ActorFilter.vendor, color: Colors.orangeAccent, onTap: () => onChanged(_ActorFilter.vendor)),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color.withValues(alpha: 0.5) : AppColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? color : AppColors.inkSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// KNOCK ROW
// ─────────────────────────────────────────────────────────────────────────
class _KnockRow extends StatelessWidget {
  final Map<String, dynamic> knock;
  const _KnockRow({required this.knock});

  @override
  Widget build(BuildContext context) {
    final isAdmin = knock['actor_type'] == 'admin';
    final granted = knock['status'] == 'GRANTED';
    final actorColor = isAdmin ? const Color(0xFF00C3FF) : Colors.orangeAccent;
    final statusColor = granted ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    final statusLabel = granted
        ? 'GRANTED'
        : (knock['status'] as String? ?? 'DENIED').replaceFirst('DENIED - ', '');
    final username = knock['username'] as String? ?? '—';
    final ip = knock['client_ip'] as String? ?? '';
    final company = knock['company'] as String?;
    final sessionSeconds = (knock['session_seconds'] as num?)?.toInt();

    final subtitleParts = <String>[
      if (ip.isNotEmpty) ip,
      if (company != null && company.isNotEmpty) company,
      if (granted && sessionSeconds != null) '${(sessionSeconds / 60).round()}m session',
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: actorColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: actorColor.withValues(alpha: 0.3), width: 0.8),
            ),
            child: Icon(
              isAdmin ? Icons.shield_outlined : Icons.storefront_outlined,
              color: actorColor,
              size: 16,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        username,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.inkPrimary, fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(color: statusColor, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                      ),
                    ),
                  ],
                ),
                if (subtitleParts.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitleParts.join('  ·  '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.inkFaint, fontSize: 10.5),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _timeLabel(knock['created_at'] as String?),
            style: const TextStyle(color: Color(0xFF475569), fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

// Wraps a newly-appeared row in a one-time fade + slide-down reveal so live
// updates read as arriving, not just silently replacing the list.
class _NewRowReveal extends StatefulWidget {
  final Widget child;
  const _NewRowReveal({super.key, required this.child});

  @override
  State<_NewRowReveal> createState() => _NewRowRevealState();
}

class _NewRowRevealState extends State<_NewRowReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 420), vsync: this)..forward();
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, -0.12), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
