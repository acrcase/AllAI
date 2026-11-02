import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../usage/usage_models.dart';
import '../../usage/usage_repository.dart';
import 'usage_card.dart';
import 'usage_format.dart';
import 'usage_strings.dart';
import 'usage_widgets.dart';

/// Panel içeriği: başlık, uygulama çipleri, kartlar. Cam ve açılış hareketi [UsageCorner]'da.
class UsagePanel extends StatefulWidget {
  const UsagePanel({
    super.key,
    required this.serviceIcons,
    required this.filter,
    required this.onFilter,
    required this.collapsed,
    required this.onToggleCard,
    this.scrollOffset = 0,
    this.onScrolled,
  });

  final Map<String, String> serviceIcons;

  /// Seçili uygulama (null = Tümü).
  final String? filter;
  final ValueChanged<String?> onFilter;
  final Set<String> collapsed;
  final ValueChanged<String> onToggleCard;

  /// Liste ilk kurulurken gidilecek konum ve kaydırma bitince bildirilen konum.
  final double scrollOffset;
  final ValueChanged<double>? onScrolled;

  @override
  State<UsagePanel> createState() => _UsagePanelState();
}

class _UsagePanelState extends State<UsagePanel> {
  final _repo = UsageRepository.instance;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // "2 dk önce" gibi göreli zamanlar panel açıkken tazelensin.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _repo,
    builder: (context, _) {
      final reports = orderedReports(_repo);
      final filter = reports.any((r) => r.serviceId == widget.filter) ? widget.filter : null;
      final shown = filter == null ? reports : reports.where((r) => r.serviceId == filter).toList();
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            lastRefresh: _repo.lastRefresh,
            busy: _repo.refreshing.isNotEmpty,
            onRefreshAll: _repo.refreshAll,
          ),
          if (filter == null && reports.isNotEmpty) _Summary(reports: reports),
          if (reports.length > 1)
            _ChipRow(
              reports: reports,
              icons: widget.serviceIcons,
              selected: filter,
              onSelect: widget.onFilter,
            )
          else
            const SizedBox(height: 10),
          const ColoredBox(color: AppColors.stroke, child: SizedBox(height: 1)),
          Flexible(
            child: AnimatedSize(
              duration: Motion.medium,
              curve: Motion.emphasized,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: Motion.medium,
                switchInCurve: Motion.emphasized,
                switchOutCurve: Motion.emphasized,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: anim.drive(Tween(begin: const Offset(0, 0.025), end: Offset.zero)),
                    child: child,
                  ),
                ),
                child: reports.isEmpty
                    ? const _EmptyState(key: ValueKey('empty'))
                    : _ServiceList(
                        key: ValueKey(filter ?? '*'),
                        reports: shown,
                        icons: widget.serviceIcons,
                        collapsed: widget.collapsed,
                        initialScroll: widget.scrollOffset,
                        onScrolled: widget.onScrolled,
                        refreshing: _repo.refreshing,
                        onToggle: widget.onToggleCard,
                        onRefresh: _repo.refresh,
                        onConnect: _repo.grantConsent,
                        onDisconnect: (id) => _repo.setConsent(id, false),
                      ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.lastRefresh, required this.busy, required this.onRefreshAll});

  final DateTime? lastRefresh;
  final bool busy;
  final VoidCallback onRefreshAll;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _build);

  Widget _build(BuildContext context, BoxConstraints box) {
    // Dar panelde (telefon) yalnız simge: alt başlık kesilmesin.
    final compact = box.maxWidth < 380;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 10, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  UsageStrings.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  lastRefresh == null
                      ? UsageStrings.neverUpdated
                      : UsageStrings.lastUpdated(UsageFormat.ago(lastRefresh!)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                ),
              ],
            ),
          ),
          Pressable(
            onTap: busy ? null : onRefreshAll,
            label: UsageStrings.refreshAll,
            tooltip: compact ? UsageStrings.refreshAll : null,
            builder: (context, hovered, pressed, focused) => Padding(
              padding: EdgeInsets.symmetric(vertical: 6, horizontal: compact ? 6 : 4),
              child: AnimatedScale(
                scale: pressed ? 0.96 : 1,
                duration: Motion.fast,
                child: AnimatedContainer(
                  duration: Motion.fast,
                  height: 32,
                  width: compact ? 32 : null,
                  padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 11),
                  decoration: BoxDecoration(
                    color: hovered ? AppColors.surfaceHi : AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: focused
                          ? AppColors.accent
                          : (hovered ? AppColors.strokeHi : AppColors.stroke),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SpinIcon(
                        spinning: busy,
                        child: Icon(
                          Icons.refresh_rounded,
                          size: 16,
                          color: busy ? AppColors.accent : AppColors.textDim,
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 6),
                        Text(
                          busy ? UsageStrings.refreshingAll : UsageStrings.refreshAll,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: hovered ? AppColors.text : AppColors.textDim,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Üst özet: en düşük kalan limit ve kaç uygulamanın dikkat istediği.
class _Summary extends StatelessWidget {
  const _Summary({required this.reports});

  final List<UsageReport> reports;

  @override
  Widget build(BuildContext context) {
    UsageReport? worst;
    var attention = 0;
    for (final r in reports) {
      final v = r.lowestRemaining;
      if (v != null && (worst == null || v < worst.lowestRemaining!)) worst = r;
      if (r.status case UsageStatus.needsLogin || UsageStatus.needsConsent || UsageStatus.error) attention++;
    }
    final low = worst?.lowestRemaining;
    final color = AppColors.forRemaining(low);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0.03)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              UsageRing(fraction: low, size: 38, stroke: 4),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      low == null ? UsageStrings.noMeasuredLimit : UsageStrings.lowestLeft((low * 100).round()),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (worst != null) worst.title,
                        UsageStrings.appCount(reports.length),
                        if (attention > 0) UsageStrings.attentionCount(attention),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Yatay uygulama çipleri; fare tekerleği de yatay kaydırır.
class _ChipRow extends StatefulWidget {
  const _ChipRow({
    required this.reports,
    required this.icons,
    required this.selected,
    required this.onSelect,
  });

  final List<UsageReport> reports;
  final Map<String, String> icons;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  State<_ChipRow> createState() => _ChipRowState();
}

class _ChipRowState extends State<_ChipRow> {
  final _scroll = ScrollController();

  static const _fadeStart = 14.0;
  static const _fadeEnd = 30.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_scroll.hasClients) return;
    final d = e.scrollDelta;
    if (d.dy == 0 || d.dx != 0) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      final p = _scroll.position;
      _scroll.jumpTo((p.pixels + d.dy).clamp(p.minScrollExtent, p.maxScrollExtent));
    });
  }

  void _select(BuildContext chipContext, String? id) {
    widget.onSelect(id);
    Scrollable.ensureVisible(
      chipContext,
      alignment: 0.5,
      duration: Motion.medium,
      curve: Motion.emphasized,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _Chip(
        key: const ValueKey('usage-chip-*'),
        label: UsageStrings.all,
        leading: const Icon(Icons.apps_rounded, size: 15, color: AppColors.textDim),
        selected: widget.selected == null,
        onTap: (c) => _select(c, null),
      ),
      for (final r in widget.reports)
        _Chip(
          key: ValueKey('usage-chip-${r.serviceId}'),
          label: r.title,
          leading: ServiceIcon(title: r.title, asset: widget.icons[r.serviceId], size: 16),
          dot: _dotColor(r),
          selected: widget.selected == r.serviceId,
          // Seçili çipe tekrar basmak Tümü'ye döner.
          onTap: (c) => _select(c, widget.selected == r.serviceId ? null : r.serviceId),
        ),
    ];
    return SizedBox(
      height: 52,
      child: Listener(
        onPointerSignal: _onSignal,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            colors: [
              AppColors.text.withValues(alpha: 0),
              AppColors.text,
              AppColors.text,
              AppColors.text.withValues(alpha: 0),
            ],
            stops: [0, _fadeStart / rect.width, 1 - _fadeEnd / rect.width, 1],
          ).createShader(rect),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context)
                .copyWith(scrollbars: false, dragDevices: PointerDeviceKind.values.toSet()),
            child: ListView.separated(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, _fadeEnd + 4, 4),
              itemCount: chips.length,
              separatorBuilder: (context, i) => const SizedBox(width: 6),
              itemBuilder: (context, i) => chips[i],
            ),
          ),
        ),
      ),
    );
  }

  static Color? _dotColor(UsageReport r) => switch (r.status) {
    UsageStatus.ok => r.lowestRemaining == null ? null : AppColors.forRemaining(r.lowestRemaining),
    UsageStatus.needsLogin || UsageStatus.needsConsent => AppColors.warn,
    UsageStatus.error => AppColors.bad,
    _ => null,
  };
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.leading,
    required this.selected,
    required this.onTap,
    this.dot,
  });

  final String label;
  final Widget leading;
  final bool selected;
  final Color? dot;
  final void Function(BuildContext chipContext) onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => onTap(context),
    label: label,
    builder: (context, hovered, pressed, focused) => Center(
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.emphasized,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.22)
              : (hovered ? AppColors.surfaceHi : AppColors.surface),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: focused
                ? AppColors.accent
                : selected
                ? AppColors.accent.withValues(alpha: 0.6)
                : (hovered ? AppColors.strokeHi : AppColors.stroke),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            const SizedBox(width: 7),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected || hovered ? AppColors.text : AppColors.textDim,
              ),
            ),
            if (dot != null) ...[
              const SizedBox(width: 7),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Kartlar. Her süzgeç için yeniden kurulur, böylece çubuklar 0'dan yeniden dolar.
class _ServiceList extends StatefulWidget {
  const _ServiceList({
    super.key,
    required this.reports,
    required this.icons,
    required this.collapsed,
    required this.initialScroll,
    required this.onScrolled,
    required this.refreshing,
    required this.onToggle,
    required this.onRefresh,
    required this.onConnect,
    required this.onDisconnect,
  });

  final List<UsageReport> reports;
  final Map<String, String> icons;
  final Set<String> collapsed;
  final double initialScroll;
  final ValueChanged<double>? onScrolled;
  final Set<String> refreshing;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onRefresh;
  final ValueChanged<String> onConnect;
  final ValueChanged<String> onDisconnect;

  @override
  State<_ServiceList> createState() => _ServiceListState();
}

class _ServiceListState extends State<_ServiceList> with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: Motion.expand + Motion.slow,
  );
  late final ScrollController _scroll = ScrollController(initialScrollOffset: widget.initialScroll);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reveal.isDismissed) {
      MediaQuery.disableAnimationsOf(context) ? _reveal.value = 1 : _reveal.forward();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _reveal.dispose();
    super.dispose();
  }

  // Satır i: önce kısa bekleme, sonra 30 ms arayla kademeli dolum.
  Animation<double> _revealFor(int i) {
    final begin = math.min(0.12 + i * 0.03, 0.5);
    return _reveal.drive(CurveTween(curve: Interval(begin, begin + 0.5, curve: Motion.emphasized)));
  }

  @override
  Widget build(BuildContext context) {
    var offset = 0;
    final cards = <Widget>[];
    for (final r in widget.reports) {
      final expanded = !widget.collapsed.contains(r.serviceId);
      cards.add(
        Padding(
          padding: EdgeInsets.only(top: cards.isEmpty ? 0 : 10),
          child: UsageCard(
            key: ValueKey('usage-card-${r.serviceId}'),
            report: r,
            icon: widget.icons[r.serviceId],
            expanded: expanded,
            refreshing: widget.refreshing.contains(r.serviceId),
            onToggle: () => widget.onToggle(r.serviceId),
            onRefresh: () => widget.onRefresh(r.serviceId),
            onConnect: () => widget.onConnect(r.serviceId),
            onDisconnect: () => widget.onDisconnect(r.serviceId),
            revealFor: _revealFor,
            revealOffset: offset,
          ),
        ),
      );
      if (expanded) offset += r.sections.fold<int>(0, (a, s) => a + s.meters.length);
    }
    return NotificationListener<ScrollEndNotification>(
      onNotification: (n) {
        if (n.depth == 0) widget.onScrolled?.call(n.metrics.pixels);
        return false;
      },
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: cards),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(28, 36, 28, 40),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insights_rounded, size: 30, color: AppColors.textFaint),
        SizedBox(height: 12),
        Text(
          UsageStrings.emptyTitle,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDim),
        ),
        SizedBox(height: 4),
        Text(
          UsageStrings.emptyBody,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.textFaint, height: 1.4),
        ),
      ],
    ),
  );
}
