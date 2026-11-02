import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/widgets/sprites.dart';
import '../../models/ai_service.dart';
import '../common/service_icon.dart';

/// Büyüyen kartın son karesiyle aynı görünüm: marka tonlu zemin, ortada simge.
/// Kart → içerik geçişi bu sayede kesintisiz görünür.
///
/// Zemin gradyanı küçük bir görüntüye bir kez çizilip büyütülür: bu makinede ekran boyu gradyan
/// dolgusu kare başına ≈ 40 ms, görüntü kopyası < 1 ms (bkz. [Sprites]).
class ServiceBackdrop extends StatelessWidget {
  const ServiceBackdrop({super.key, required this.service, this.strength = 1, this.child});

  final AiService service;
  final double strength;
  final Widget? child;

  /// [r]'yi marka tonlu zeminle boyar: küçük gradyan görüntüsü büyütülür, hazır değilse düz ton.
  /// Büyüyen kart da bunu kullanır; son kare birebir aynı olsun.
  static void paintOn(Canvas canvas, Rect r, Color color, Color accent, {double strength = 1, double opacity = 1}) {
    final img = Sprites.gradient(
      'backdrop-${color.toARGB32()}-${accent.toARGB32()}-$strength',
      LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(AppColors.bg, color, 0.24 * strength)!,
          AppColors.bg,
          Color.lerp(AppColors.bg, accent, 0.10 * strength)!,
        ],
        stops: const [0, 0.6, 1],
      ),
      width: 128,
      height: 80,
    );
    if (img == null) {
      canvas.drawRect(r, Paint()..color = Color.lerp(AppColors.bg, color, 0.10 * strength)!.withValues(alpha: opacity));
      return;
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      r,
      Paint()
        ..filterQuality = FilterQuality.low
        ..color = Color.fromRGBO(255, 255, 255, opacity),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BackdropPainter(service.color, service.accent, strength),
      child: child ?? const SizedBox.expand(),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.color, this.accent, this.strength) : super(repaint: Sprites.ready);

  final Color color;
  final Color accent;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) => ServiceBackdrop.paintOn(canvas, Offset.zero & size, color, accent, strength: strength);

  @override
  bool shouldRepaint(_BackdropPainter old) => old.color != color || old.accent != accent || old.strength != strength;
}

class LoadingSplash extends StatefulWidget {
  const LoadingSplash({super.key, required this.service, this.label, this.child});

  static const iconSize = 116.0;

  final AiService service;
  final String? label;

  /// Simgenin altında ek içerik (izin düğmeleri vb.).
  final Widget? child;

  @override
  State<LoadingSplash> createState() => _LoadingSplashState();
}

class _LoadingSplashState extends State<LoadingSplash> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    const box = LoadingSplash.iconSize * 2;
    // Simge kutusu tam ortada (büyüyen kartın son karesi de öyle); yazı ve ek içerik altında.
    return ServiceBackdrop(
      service: s,
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          children: [
            Center(
              child: SizedBox.square(
                dimension: box,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) => CustomPaint(
                    painter: SplashRingsPainter(_pulse.value, s.color, s.accent),
                    child: child,
                  ),
                  child: Center(child: ServiceIcon(s, size: LoadingSplash.iconSize)),
                ),
              ),
            ),
            if (widget.label != null || widget.child != null)
              Positioned(
                left: 24,
                right: 24,
                top: c.maxHeight / 2 + box / 2,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.label != null)
                      Text(
                        widget.label!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14, height: 1.45, color: AppColors.textDim),
                      ),
                    if (widget.child != null) ...[const SizedBox(height: 18), widget.child!],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Simgenin arkasındaki ışıma ve dışa yayılan iki halka. [opacity] büyüyen kartta belirmek için.
class SplashRingsPainter extends CustomPainter {
  SplashRingsPainter(this.t, this.color, this.accent, {this.opacity = 1});

  final double t;
  final Color color;
  final Color accent;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.002) return;
    final c = size.center(Offset.zero);
    final k = size.width / (LoadingSplash.iconSize * 2);
    final base = LoadingSplash.iconSize * 0.42 * k;
    canvas.drawCircle(
      c,
      base * 1.25,
      Paint()
        ..color = color.withValues(alpha: 0.35 * opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 30 * k),
    );
    for (var i = 0; i < 2; i++) {
      final p = (t + i * 0.5) % 1;
      canvas.drawCircle(
        c,
        base + p * size.width * 0.42,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Color.lerp(color, accent, p)!.withValues(alpha: (1 - p) * 0.55 * opacity),
      );
    }
  }

  @override
  bool shouldRepaint(SplashRingsPainter old) => old.t != t || old.opacity != opacity || old.color != color;
}
