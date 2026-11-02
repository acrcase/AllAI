import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../usage/usage_models.dart';
import '../../usage/usage_repository.dart';
import '../common/service_icon.dart';

/// Panelde gösterilecek raporlar: önce [UsageRepository.order], sonra kalanlar.
List<UsageReport> orderedReports(UsageRepository repo) {
  final seen = <String>{};
  final out = <UsageReport>[];
  for (final id in repo.order) {
    final r = repo.reports[id];
    if (r != null && seen.add(id)) out.add(r);
  }
  for (final e in repo.reports.entries) {
    if (seen.add(e.key)) out.add(e.value);
  }
  return out;
}

/// Bütün raporlardaki en düşük kalan oran (düğme halkası için).
double? lowestOverall(Iterable<UsageReport> reports) {
  double? low;
  for (final r in reports) {
    final v = r.lowestRemaining;
    if (v != null && (low == null || v < low)) low = v;
  }
  return low;
}

typedef PressBuilder = Widget Function(
  BuildContext context,
  bool hovered,
  bool pressed,
  bool focused,
);

/// Fare (hover, el imleci), dokunma (basılı) ve klavye (odak, Enter/Boşluk) davranışı tek yerde.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.label,
    this.tooltip,
    this.expanded,
  });

  final VoidCallback? onTap;
  final PressBuilder builder;
  final String? label;
  final String? tooltip;
  final bool? expanded;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hover = false;
  bool _down = false;
  bool _focus = false;

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget child = FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (v) => _set(() => _hover = v),
      onShowFocusHighlight: (v) => _set(() => _focus = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(() => _down = true) : null,
        onTapUp: enabled ? (_) => _set(() => _down = false) : null,
        onTapCancel: enabled ? () => _set(() => _down = false) : null,
        onTap: widget.onTap,
        child: widget.builder(context, _hover && enabled, _down, _focus),
      ),
    );
    child = Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      expanded: widget.expanded,
      child: child,
    );
    if (widget.tooltip != null) child = Tooltip(message: widget.tooltip!, child: child);
    return child;
  }
}

/// Kalan oranı gösteren halka. [spin] verilirse belirsiz dönen yay çizer (yenileniyor).
class UsageRing extends StatelessWidget {
  const UsageRing({
    super.key,
    required this.fraction,
    this.size = 18,
    this.stroke = 2.4,
    this.spin,
    this.glow = 0,
  });

  final double? fraction;
  final double size;
  final double stroke;
  final double? spin;
  final double glow;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.forRemaining(fraction);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: fraction ?? 0),
      duration: Motion.slow,
      curve: Motion.emphasized,
      builder: (context, v, _) => CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(
          fraction: fraction == null ? null : v,
          color: color,
          stroke: stroke,
          spin: spin,
          glow: glow,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.color,
    required this.stroke,
    required this.spin,
    required this.glow,
  });

  final double? fraction;
  final Color color;
  final double stroke;
  final double? spin;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = (size.shortestSide - stroke) / 2;
    if (glow > 0) {
      canvas.drawCircle(
        c,
        r + stroke,
        Paint()
          ..color = color.withValues(alpha: 0.55 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.shortestSide * 0.35),
      );
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    // Tükenmiş (0) halka boş kalmasın: iz rengi durum rengine döner.
    final exhausted = spin == null && fraction == 0;
    canvas.drawCircle(
      c,
      r,
      line..color = exhausted ? color.withValues(alpha: 0.5) : AppColors.strokeHi,
    );
    final rect = Rect.fromCircle(center: c, radius: r);
    if (spin != null) {
      final start = -math.pi / 2 + spin! * 2 * math.pi;
      canvas.drawArc(rect, start, math.pi * 0.6, false, line..color = color);
      return;
    }
    final f = fraction;
    if (f == null || f <= 0) return;
    final sweep = 2 * math.pi * math.max(f.clamp(0.0, 1.0), 0.03);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, line..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter o) =>
      o.fraction != fraction ||
      o.color != color ||
      o.spin != spin ||
      o.glow != glow ||
      o.stroke != stroke;
}

enum BarKind { value, unlimited, unknown }

/// Ölçer çubuğu. [fill] 0..1 çizilen oran; bilinmeyende çizgili desen o kadar açılır.
class MeterBar extends StatelessWidget {
  const MeterBar({
    super.key,
    required this.fill,
    required this.color,
    required this.kind,
    this.empty = false,
    this.height = 6,
  });

  final double fill;
  final Color color;
  final BarKind kind;
  final bool empty;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(
      painter: _BarPainter(fill: fill.clamp(0.0, 1.0), color: color, kind: kind, empty: empty),
    ),
  );
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.fill, required this.color, required this.kind, required this.empty});

  final double fill;
  final Color color;
  final BarKind kind;
  final bool empty;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(
      track,
      Paint()..color = empty ? AppColors.bad.withValues(alpha: 0.18) : AppColors.surfaceHi,
    );
    final w = size.width * fill;
    if (kind == BarKind.unknown) {
      canvas.save();
      canvas.clipRRect(track);
      canvas.clipRect(Rect.fromLTWH(0, 0, w, size.height));
      final p = Paint()
        ..color = AppColors.strokeHi
        ..strokeWidth = 1.6;
      for (var x = -size.height; x < w; x += 5) {
        canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
      }
      canvas.restore();
      return;
    }
    if (w <= 0) return;
    final rect = Rect.fromLTWH(0, 0, math.max(w, size.height), size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()
        ..shader = LinearGradient(colors: [color.withValues(alpha: 0.55), color])
            .createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_BarPainter o) =>
      o.fill != fill || o.color != color || o.kind != kind || o.empty != empty;
}

/// Uygulama simgesi; varlık yoksa ya da açılamazsa baş harf rozeti.
class ServiceIcon extends StatelessWidget {
  const ServiceIcon({super.key, required this.title, this.asset, this.size = 28});

  final String title;
  final String? asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.28);
    final badge = _badge(radius);
    if (asset == null) return badge;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: radius,
      child: Image(
        image: ResizeImage(iconImage(asset!), width: px),
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => badge,
      ),
    );
  }

  Widget _badge(BorderRadius radius) {
    final initial = title.trim().isEmpty ? '?' : title.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: AppColors.stroke),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            // Gümüş vurgu açık renk: beyaz baş harf ≥ 4,5:1 kalsın diye sönük.
            AppColors.accent.withValues(alpha: 0.30),
            AppColors.accent.withValues(alpha: 0.10),
          ],
        ),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.46,
          fontWeight: FontWeight.w700,
          color: AppColors.text,
          height: 1,
        ),
      ),
    );
  }
}

/// Küçük hap etiket: plan adı, "tahmini", durum.
class UsageTag extends StatelessWidget {
  const UsageTag(
    this.text, {
    super.key,
    this.color = AppColors.textDim,
    this.icon,
    this.filled = false,
    this.maxWidth = 150,
  });

  final String text;
  final Color color;
  final IconData? icon;
  final bool filled;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    // Dolgulu etikette yazı beyaz: renkli zemin üstünde renkli yazı okunmuyor (ölçüm ~3.7:1).
    final fg = filled ? AppColors.text : color;
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.16) : null,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: filled ? 0.28 : 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: fg), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: fg,
                height: 1.2,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dönen simge; durunca turu tamamlayıp yumuşak durur.
class SpinIcon extends StatefulWidget {
  const SpinIcon({super.key, required this.spinning, required this.child});

  final bool spinning;
  final Widget child;

  @override
  State<SpinIcon> createState() => _SpinIconState();
}

class _SpinIconState extends State<SpinIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.expand + Motion.slow,
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _c.repeat();
  }

  @override
  void didUpdateWidget(SpinIcon old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !old.spinning) {
      _c
        ..value = 0
        ..repeat();
    } else if (!widget.spinning && old.spinning) {
      _c.forward(from: _c.value);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: widget.child);
}

/// Yüklenirken iskelet satırları ve üstlerinde kayan parıltı.
class SkeletonRows extends StatefulWidget {
  const SkeletonRows({super.key, this.rows = 3});

  final int rows;

  @override
  State<SkeletonRows> createState() => _SkeletonRowsState();
}

class _SkeletonRowsState extends State<SkeletonRows> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.expand * 2)
    ..repeat();

  static const _widths = [0.52, 0.68, 0.40, 0.58];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _box(double t, double height, double widthFactor) => FractionallySizedBox(
    alignment: Alignment.centerLeft,
    widthFactor: widthFactor,
    child: Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height / 2),
        gradient: LinearGradient(
          colors: const [AppColors.surface, AppColors.strokeHi, AppColors.surface],
          stops: const [0.3, 0.5, 0.7],
          transform: _SlideGradient(t),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.rows; i++) ...[
          const SizedBox(height: 14),
          _box(_c.value, 10, _widths[i % _widths.length]),
          const SizedBox(height: 8),
          _box(_c.value, 6, 1),
        ],
      ],
    ),
  );
}

class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);

  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}
