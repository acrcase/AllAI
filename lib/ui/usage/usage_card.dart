import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../usage/usage_models.dart';
import 'usage_format.dart';
import 'usage_strings.dart';
import 'usage_widgets.dart';

/// Bir uygulamanın katlanabilir limit kartı.
class UsageCard extends StatefulWidget {
  const UsageCard({
    super.key,
    required this.report,
    required this.icon,
    required this.expanded,
    required this.refreshing,
    required this.onToggle,
    required this.onRefresh,
    required this.onConnect,
    required this.onDisconnect,
    required this.revealFor,
    required this.revealOffset,
  });

  final UsageReport report;
  final String? icon;
  final bool expanded;
  final bool refreshing;
  final VoidCallback onToggle;
  final VoidCallback onRefresh;

  /// Onay gerektiren satırda "bağla" düğmesine basınca (anahtarlık okuması o an başlar).
  final VoidCallback onConnect;

  /// Bağlı satırda "bağlantıyı kes": onay geri alınır, türetilen anahtar bellekten silinir.
  final VoidCallback onDisconnect;

  /// Satır sırasına göre kademeli dolum animasyonu.
  final Animation<double> Function(int index) revealFor;
  final int revealOffset;

  @override
  State<UsageCard> createState() => _UsageCardState();
}

class _UsageCardState extends State<UsageCard> with SingleTickerProviderStateMixin {
  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: Motion.medium,
    value: widget.expanded ? 1 : 0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(parent: _expand, curve: Motion.emphasized);
  late final Animation<double> _chevron = _curve.drive(Tween(begin: 0, end: 0.5));

  @override
  void didUpdateWidget(UsageCard old) {
    super.didUpdateWidget(old);
    if (widget.expanded != old.expanded) {
      widget.expanded ? _expand.forward() : _expand.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _expand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _body(widget.report);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(widget.report),
          AnimatedBuilder(
            animation: _expand,
            builder: (context, child) => _expand.isDismissed ? const SizedBox.shrink() : child!,
            child: SizeTransition(
              sizeFactor: _curve,
              alignment: Alignment.topLeft,
              child: FadeTransition(opacity: _curve, child: body),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(UsageReport r) => Pressable(
    onTap: widget.onToggle,
    label: r.title,
    expanded: widget.expanded,
    builder: (context, hovered, pressed, focused) => AnimatedContainer(
      duration: Motion.fast,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: hovered || pressed ? AppColors.surface : AppColors.surface.withValues(alpha: 0),
        borderRadius: widget.expanded
            ? const BorderRadius.vertical(top: Radius.circular(15))
            : BorderRadius.circular(15),
        border: focused ? Border.all(color: AppColors.accent) : null,
      ),
      child: Row(
        children: [
          ServiceIcon(title: r.title, asset: widget.icon, size: 30),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 3),
                // Plan çipi ikinci satırda: dar ekranda başlığı ezmesin.
                Row(
                  children: [
                    if (r.plan != null) ...[
                      UsageTag(r.plan!, color: AppColors.accent, filled: true, maxWidth: 120),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        _subtitle(r),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _summary(r),
          _IconAction(
            icon: Icons.refresh_rounded,
            tooltip: UsageStrings.refresh,
            spinning: widget.refreshing,
            onTap: widget.onRefresh,
          ),
          RotationTransition(
            turns: _chevron,
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: AppColors.textFaint,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    ),
  );

  String _subtitle(UsageReport r) {
    final when = UsageFormat.ago(r.fetchedAt);
    final n = r.sections.fold<int>(0, (a, s) => a + s.meters.length);
    if (r.status == UsageStatus.ok && n > 0) return '${UsageStrings.meterCount(n)} · $when';
    return UsageStrings.updatedAgo(when);
  }

  Widget _summary(UsageReport r) {
    switch (r.status) {
      case UsageStatus.ok:
        final meters = [for (final s in r.sections) ...s.meters];
        if (meters.isNotEmpty && meters.every((m) => m.unlimited)) {
          return UsageTag(
            UsageStrings.unlimited,
            color: AppColors.accent,
            icon: Icons.all_inclusive_rounded,
          );
        }
        UsageMeter? low;
        for (final m in meters) {
          final v = m.unlimited ? 1.0 : m.remaining;
          if (v == null) continue;
          final lv = low == null ? null : (low.unlimited ? 1.0 : low.remaining!);
          if (lv == null || v < lv) low = m;
        }
        if (low == null) return const SizedBox.shrink();
        final v = low.unlimited ? 1.0 : low.remaining!;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UsageRing(fraction: v, size: 15, stroke: 2.2),
            const SizedBox(width: 6),
            Text(
              '${low.estimated ? '~' : ''}${UsageFormat.percent(v)}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.forRemaining(v),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      case UsageStatus.loading:
        return UsageTag(UsageStrings.statusLoading, color: AppColors.textDim);
      case UsageStatus.needsLogin:
        return UsageTag(
          UsageStrings.statusNeedsLogin,
          color: AppColors.warn,
          icon: Icons.lock_outline_rounded,
        );
      case UsageStatus.needsConsent:
        return UsageTag(
          UsageStrings.statusNeedsConsent,
          color: AppColors.warn,
          icon: Icons.link_rounded,
        );
      case UsageStatus.unavailable:
        return UsageTag(UsageStrings.statusUnavailable, color: AppColors.textDim);
      case UsageStatus.noData:
        return UsageTag(UsageStrings.statusNoData, color: AppColors.textDim);
      case UsageStatus.error:
        return UsageTag(
          UsageStrings.statusError,
          color: AppColors.bad,
          icon: Icons.error_outline_rounded,
        );
    }
  }

  Widget _body(UsageReport r) {
    final children = <Widget>[];
    final banner = _banner(r);
    if (banner != null) {
      children.add(Padding(padding: const EdgeInsets.only(top: 4), child: banner));
    }
    if (r.status == UsageStatus.loading && r.sections.isEmpty) {
      children.add(const SkeletonRows());
    }
    var index = widget.revealOffset;
    for (final s in r.sections) {
      if (s.meters.isEmpty) continue;
      final common = _commonReset(s);
      if (s.title != null || common != null) {
        children.add(_SectionTitle(s.title, reset: common, first: children.isEmpty));
      }
      for (final m in s.meters) {
        children.add(
          MeterRow(
            meter: m,
            reveal: widget.revealFor(index++),
            expand: _curve,
            showReset: common == null,
          ),
        );
      }
    }
    final notes = [
      if (banner == null && r.message != null) r.message!,
      if (r.source != null) UsageStrings.source(r.source!),
    ];
    for (final n in notes) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            n,
            style: const TextStyle(fontSize: 11, color: AppColors.textFaint, height: 1.35),
          ),
        ),
      );
    }
    // Kullanıcı bu hesabı bağladıysa (onay verdiyse) bağlantıyı kesme seçeneği (44 px dokunma alanı).
    if (r.connected && r.status != UsageStatus.needsConsent) {
      children.add(
        Pressable(
          onTap: widget.onDisconnect,
          label: UsageStrings.disconnectAccount,
          builder: (context, hovered, pressed, focused) => SizedBox(
            height: 44,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.link_off_rounded,
                      size: 13, color: hovered ? AppColors.text : AppColors.textFaint),
                  const SizedBox(width: 5),
                  Text(
                    UsageStrings.disconnectAccount,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: hovered ? AppColors.text : AppColors.textFaint,
                      decoration: focused ? TextDecoration.underline : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  /// Bölümdeki bütün sınırlı ölçerler aynı anda yenileniyorsa zaman bir kez, başlıkta yazılır.
  static DateTime? _commonReset(UsageSection s) {
    final limited = s.meters.where((m) => !m.unlimited).toList();
    if (limited.length < 2) return null;
    final first = limited.first.resetsAt;
    if (first == null) return null;
    for (final m in limited) {
      final at = m.resetsAt;
      if (at == null || at.difference(first).inMinutes.abs() >= 1) return null;
    }
    return first;
  }

  Widget? _banner(UsageReport r) => switch (r.status) {
    UsageStatus.ok || UsageStatus.loading => null,
    UsageStatus.needsLogin => _StateBanner(
      icon: Icons.lock_outline_rounded,
      color: AppColors.warn,
      text: r.message ?? UsageStrings.defaultNeedsLogin,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.arrow_outward_rounded, size: 14, color: AppColors.accent),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              UsageStrings.loginHint,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.accent),
            ),
          ),
        ],
      ),
    ),
    UsageStatus.needsConsent => _StateBanner(
      icon: Icons.link_rounded,
      color: AppColors.warn,
      text: r.message ?? UsageStrings.defaultNeedsConsent,
      action: _ConnectButton(
        label: r.actionLabel ?? UsageStrings.connectAccount,
        onTap: widget.onConnect,
      ),
    ),
    UsageStatus.unavailable => _StateBanner(
      icon: Icons.block_rounded,
      color: AppColors.textFaint,
      text: r.message ?? UsageStrings.defaultUnavailable,
    ),
    UsageStatus.noData => _StateBanner(
      icon: Icons.info_outline_rounded,
      color: AppColors.textDim,
      text: r.message ?? UsageStrings.defaultNoData,
    ),
    UsageStatus.error => _StateBanner(
      icon: Icons.error_outline_rounded,
      color: AppColors.bad,
      text: r.message ?? UsageStrings.defaultError,
      action: _RetryButton(spinning: widget.refreshing, onTap: widget.onRefresh),
    ),
  };
}

/// Etiket, kalan oran, dolan çubuk, ayrıntı ve sıfırlanma.
class MeterRow extends StatelessWidget {
  const MeterRow({
    super.key,
    required this.meter,
    required this.reveal,
    required this.expand,
    this.showReset = true,
  });

  final UsageMeter meter;
  final Animation<double> reveal;
  final Animation<double> expand;

  /// Bölüm başlığı ortak sıfırlanmayı gösteriyorsa satırda tekrarlanmaz.
  final bool showReset;

  @override
  Widget build(BuildContext context) {
    final m = meter;
    final target = m.unlimited ? 1.0 : m.remaining;
    final color = m.unlimited ? AppColors.accent : AppColors.forRemaining(m.remaining);
    final kind = m.unlimited
        ? BarKind.unlimited
        : (m.remaining == null ? BarKind.unknown : BarKind.value);
    final progress = Listenable.merge([reveal, expand]);
    final reset = showReset ? m.resetsAt : null;
    double factor() => reveal.value * expand.value;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: (target ?? 1).clamp(0.0, 1.0)),
        duration: Motion.slow,
        curve: Motion.emphasized,
        builder: (context, value, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    m.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.text,
                      height: 1.25,
                    ),
                  ),
                ),
                if (m.estimated) ...[
                  const SizedBox(width: 6),
                  UsageTag(UsageStrings.estimated, color: AppColors.textDim),
                ],
                const SizedBox(width: 10),
                AnimatedBuilder(
                  animation: progress,
                  builder: (context, _) => Text(
                    _valueText(m, value * factor()),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: target == null ? AppColors.textFaint : color,
                      height: 1.3,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            AnimatedBuilder(
              animation: progress,
              builder: (context, _) => MeterBar(
                fill: kind == BarKind.unknown ? factor() : value * factor(),
                color: color,
                kind: kind,
                empty: target == 0,
              ),
            ),
            if (m.detail != null || reset != null) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (m.detail != null)
                    Text(
                      m.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
                    ),
                  if (reset != null) _ResetLabel(reset),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _valueText(UsageMeter m, double shown) {
    if (m.unlimited) return UsageStrings.unlimited;
    if (m.remaining == null) return UsageStrings.unknown;
    return '${m.estimated ? '~' : ''}${UsageStrings.percentLeft(UsageFormat.percent(shown))}';
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {required this.first, this.reset});

  final String? text;
  final DateTime? reset;
  final bool first;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: first ? 6 : 18),
    // Sığarsa iki uca yayılır, sığmazsa sıfırlanma alt satıra iner (kesilmez).
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        if (text != null)
          Text(
            text!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textDim,
              letterSpacing: 0.4,
            ),
          ),
        if (reset != null) _ResetLabel(reset!),
      ],
    ),
  );
}

class _ResetLabel extends StatelessWidget {
  const _ResetLabel(this.at);

  final DateTime at;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.schedule_rounded, size: 12, color: AppColors.textDim),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          UsageFormat.reset(at),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
        ),
      ),
    ],
  );
}

class _StateBanner extends StatelessWidget {
  const _StateBanner({required this.icon, required this.color, required this.text, this.action});

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.22)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: const TextStyle(fontSize: 12.5, color: AppColors.textDim, height: 1.35),
              ),
              if (action != null) ...[const SizedBox(height: 1), action!],
            ],
          ),
        ),
      ],
    ),
  );
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.spinning, required this.onTap});

  final bool spinning;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed, focused) => AnimatedScale(
      scale: pressed ? 0.96 : 1,
      duration: Motion.fast,
      child: AnimatedContainer(
        duration: Motion.fast,
        height: 30,
        // 30 px görünür, 44 px dokunma alanı.
        margin: const EdgeInsets.symmetric(vertical: 7),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: AppColors.bad.withValues(alpha: hovered ? 0.24 : 0.14),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: focused ? AppColors.accent : AppColors.bad.withValues(alpha: 0.38),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SpinIcon(
              spinning: spinning,
              child: const Icon(Icons.refresh_rounded, size: 14, color: AppColors.text),
            ),
            const SizedBox(width: 6),
            Text(
              UsageStrings.retry,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.text),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Onay gerektiren satırda bağlama düğmesi: basınca anahtarlık okuması başlar.
class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    label: label,
    builder: (context, hovered, pressed, focused) => AnimatedScale(
      scale: pressed ? 0.96 : 1,
      duration: Motion.fast,
      child: AnimatedContainer(
        duration: Motion.fast,
        height: 30,
        // 30 px görünür, 44 px dokunma alanı.
        margin: const EdgeInsets.symmetric(vertical: 7),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: hovered ? 0.3 : 0.18),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: focused ? AppColors.accent : AppColors.accent.withValues(alpha: 0.42),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_rounded, size: 14, color: AppColors.text),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.text),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Kart başlığındaki simge düğmesi: 44 px dokunma alanı, 32 px görünür daire.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.spinning = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool spinning;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    tooltip: tooltip,
    label: tooltip,
    builder: (context, hovered, pressed, focused) => SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: AnimatedContainer(
          duration: Motion.fast,
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hovered || pressed
                ? AppColors.surfaceHi
                : AppColors.surfaceHi.withValues(alpha: 0),
            border: focused ? Border.all(color: AppColors.accent) : null,
          ),
          child: SpinIcon(
            spinning: spinning,
            child: Icon(icon, size: 17, color: hovered ? AppColors.text : AppColors.textDim),
          ),
        ),
      ),
    ),
  );
}
