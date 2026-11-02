import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/widgets/sprites.dart';
import '../../models/ai_service.dart';
import '../common/service_icon.dart';
import '../home/ai_tile.dart';
import 'loading_splash.dart';

/// Kartın bulunduğu yerden içerik alanına büyüyen (ve geri küçülen) yüzey.
/// v=0'da kartın kendisi, v=1'de [LoadingSplash] ile aynı kare (zemin + ortada simge + halkalar).
/// Tıklanan noktadan ışık dalgası yayılır.
class ExpandingCard extends StatelessWidget {
  const ExpandingCard({
    super.key,
    required this.service,
    required this.from,
    required this.to,
    required this.v,
    this.tapAt,
    this.lifted = false,
  });

  final AiService service;
  final Rect from;
  final Rect to;
  final double v;

  /// Tıklanan nokta (ekran koordinatı); klavyeyle açılınca null.
  final Offset? tapAt;

  /// Kart hover pozundaydı (fareyle tıklandı): büyüme o pozdan başlar, sıçrama olmaz.
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final s = service;
    final k = from.width / AiTile.design.width;
    final start = lifted
        ? Rect.fromCenter(
            center: from.center.translate(0, -Motion.hoverLift),
            width: from.width * (1 + Motion.hoverScale),
            height: from.height * (1 + Motion.hoverScale),
          )
        : from;
    final rect = Rect.lerp(start, to, v)!;
    final ik = start.width / AiTile.design.width;
    var iconFrom = AiTile.iconRect(start.size).shift(start.topLeft);
    if (lifted) {
      iconFrom = Rect.fromCenter(center: iconFrom.center.translate(0, -5 * ik), width: iconFrom.width * 1.07, height: iconFrom.height * 1.07);
    }
    final iconTo = Rect.fromCenter(center: to.center, width: LoadingSplash.iconSize, height: LoadingSplash.iconSize);
    final icon = Rect.lerp(iconFrom, iconTo, v)!;
    final textOut = (1 - v * 3).clamp(0.0, 1.0);
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            child: CustomPaint(painter: _CardPainter(s, v, k, tapAt == null ? null : tapAt! - rect.topLeft)),
          ),
          if (textOut > 0)
            Positioned(
              left: rect.left,
              width: rect.width,
              top: rect.top + 132 * ik,
              child: Opacity(
                opacity: textOut,
                child: Transform.scale(
                  scale: ik,
                  alignment: Alignment.topCenter,
                  child: Column(
                    children: [
                      Text(s.name,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.text, letterSpacing: -0.2)),
                      const SizedBox(height: 4),
                      Text(s.subtitle, maxLines: 1, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
                    ],
                  ),
                ),
              ),
            ),
          // Simge ışıması v=1'de LoadingSplash'in t=0 halkalarıyla aynı.
          Positioned.fromRect(
            rect: Rect.fromCenter(center: icon.center, width: icon.width * 2, height: icon.height * 2),
            child: CustomPaint(painter: SplashRingsPainter(0, s.color, s.accent, opacity: v)),
          ),
          Positioned.fromRect(rect: icon, child: ServiceIcon(s, size: icon.width)),
        ],
      ),
    );
  }
}

class _CardPainter extends CustomPainter {
  _CardPainter(this.s, this.v, this.k, this.tap);

  final AiService s;
  final double v;
  final double k;
  final Offset? tap;

  @override
  void paint(Canvas c, Size size) {
    final r = Offset.zero & size;
    final radius = lerpDouble(26 * k, 0, Curves.easeIn.transform(v))!;
    final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
    final out = 1 - v;
    if (out > 0.01) {
      // Gölgeler sabit köşe yarıçapıyla: Skia'nın yuvarlak dikdörtgen bulanıklık önbelleği (yarıçap + sigma
      // anahtarlı) her karede tutar. Köşesi her karede değişen bulanık gölge, maske her karede yeniden
      // üretildiği için büyüme/küçülmede kare başına birkaç ms ekliyordu.
      final shadow = RRect.fromRectAndRadius(r, Radius.circular(26 * k));
      c.drawRRect(
        shadow.shift(Offset(0, 18 * out)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4 * out)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
      c.drawRRect(
        shadow.deflate(8).shift(Offset(0, 18 * out)),
        Paint()
          ..color = s.color.withValues(alpha: 0.45 * out)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
      );
    }
    c.save();
    c.clipRRect(rr);
    // Kartın camı marka tonlu zemine karışır.
    final bg = Curves.easeOut.transform((v / 0.45).clamp(0.0, 1.0));
    if (bg < 1) c.drawRect(r, Paint()..color = Color.lerp(AppColors.bgElevated, s.color, 0.20)!.withValues(alpha: 0.94));
    ServiceBackdrop.paintOn(c, r, s.color, s.accent, opacity: bg);
    // Tıklanan noktadan yayılan ışık dalgası.
    final p = tap ?? r.center;
    final w = (v / 0.6).clamp(0.0, 1.0);
    if (w < 1) {
      final rad = size.longestSide * 1.1 * math.pow(w, 0.7) + 20;
      Sprites.paint(c, Sprites.ring, Rect.fromCircle(center: p, radius: rad),
          Color.lerp(Colors.white, s.accent, 0.35)!.withValues(alpha: 0.42 * (1 - w)), blend: BlendMode.plus);
      Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: p, radius: 120 * k + rad * 0.35),
          s.accent.withValues(alpha: 0.22 * (1 - w)), blend: BlendMode.plus);
    }
    c.restore();
    if (out > 0.01) {
      c.drawRRect(
        rr.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = s.accent.withValues(alpha: 0.6 * out),
      );
    }
  }

  @override
  bool shouldRepaint(_CardPainter old) => old.v != v || old.tap != tap || old.s != s;
}
