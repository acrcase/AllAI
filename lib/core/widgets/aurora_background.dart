import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../motion.dart';
import '../theme.dart';
import 'ambient_clock.dart';
import 'sprites.dart';

/// Canlı zemin (kozmik tema): derin siyah, çok soluk galaksi tozu, beyaz yıldızlar (paralaks, ışıldama)
/// ve dört köşeli parıltılar; imleci izleyen sönük ışık, üzerine gelinen kartın rengine kayan ton.
///
/// Toz + gren pencere boyunda tek bir görüntüye bir kez, çizim dışında ve eşzamansız çizilir; her karede
/// yalnız kaydırılır (tam ekran tek geçiş). Ölçüm (Intel UHD 630, Skia): eski bulutsu iki anahtar kare +
/// ayrı gren + üç geniş ışıkla kare başına ~5 tam ekran geçişti, 9 sn'de bir anahtar kare üretimi de
/// raster iş parçacığını kesiyordu. Görüntü durağan önbellekte: zemin yeniden kurulunca (ana ekrana
/// dönüş) beklemeden çizilir. Boşta [AmbientClock] ile 30 Hz; fare hareketi ağacı yeniden kurmaz.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.pointer, required this.tint, this.intensity = 1});

  /// İmleç, pencereye göre 0..1; pencere dışında null.
  final ValueListenable<Offset?> pointer;

  /// Üzerine gelinen ya da açılan kartın rengi.
  final ValueListenable<Color?> tint;
  final double intensity;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  final _repaint = Pulse();
  final _clock = AmbientClock.instance;
  late final Ticker _motion = createTicker(_tick);
  Duration _last = Duration.zero;

  // Yumuşatılmış değerler.
  Offset glowPos = const Offset(0.5, 0.45);
  double glowAmt = 0;
  Color tint = AppColors.accent;
  double tintAmt = 0;
  late double intensity = widget.intensity;

  @override
  void initState() {
    super.initState();
    Sprites.init();
    _Dust.ready.addListener(_notify);
    _clock
      ..attach()
      ..addListener(_notify);
    widget.pointer.addListener(_wake);
    widget.tint.addListener(_wake);
  }

  @override
  void didUpdateWidget(AuroraBackground old) {
    super.didUpdateWidget(old);
    if (old.pointer != widget.pointer) {
      old.pointer.removeListener(_wake);
      widget.pointer.addListener(_wake);
    }
    if (old.tint != widget.tint) {
      old.tint.removeListener(_wake);
      widget.tint.addListener(_wake);
    }
    _wake();
  }

  @override
  void dispose() {
    widget.pointer.removeListener(_wake);
    widget.tint.removeListener(_wake);
    _Dust.ready.removeListener(_notify);
    _clock
      ..removeListener(_notify)
      ..detach();
    _motion.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _notify() => _repaint.ping();

  void _wake() {
    if (!_motion.isActive) {
      _last = Duration.zero;
      _motion.start();
    }
  }

  void _tick(Duration e) {
    final dt = _last == Duration.zero ? 1 / 60 : (e - _last).inMicroseconds / 1e6;
    _last = e;
    double ease(double k) => 1 - math.exp(-k * dt);

    final p = widget.pointer.value;
    final glowTarget = p == null ? 0.0 : 1.0;
    final c = widget.tint.value;
    final tintTarget = c == null ? 0.0 : 1.0;

    if (p != null) glowPos = Offset.lerp(glowPos, p, ease(Motion.glowK))!;
    glowAmt += (glowTarget - glowAmt) * ease(Motion.glowK * 0.6);
    final tk = ease(Motion.tintK);
    if (c != null) tint = Color.lerp(tint, c, tk)!;
    tintAmt += (tintTarget - tintAmt) * tk;
    intensity += (widget.intensity - intensity) * ease(Motion.tintK);

    final settled = (p == null || (glowPos - p).distance < 0.0008) &&
        (glowAmt - glowTarget).abs() < 0.002 &&
        (tintAmt - tintTarget).abs() < 0.002 &&
        (c == null || _close(tint, c)) &&
        (intensity - widget.intensity).abs() < 0.002;
    _notify();
    if (settled) _motion.stop();
  }

  static bool _close(Color a, Color b) => (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs() < 0.004;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _NebulaPainter(this, MediaQuery.devicePixelRatioOf(context)),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Toz + gren görüntüsü: durağan önbellek (bütün zeminler paylaşır). Boyut değişince eldeki görüntü
/// gerilerek çizilir, yenisi boyut 250 ms durulduktan sonra üretilir (pencere sürüklenip büyütülürken
/// her karede üretim olmasın).
abstract final class _Dust {
  static final Future<ui.FragmentProgram?> _program =
      ui.FragmentProgram.fromAsset('shaders/nebula.frag').then<ui.FragmentProgram?>((p) => p, onError: (_) => null);

  static ui.Image? _img;
  static Size _imgSize = Size.zero;
  static Size _want = Size.zero;
  static bool _rendering = false;
  static Timer? _settle;
  static final ready = ValueNotifier<int>(0);

  /// Eldeki görüntü (boyutu farklı olabilir); gerekiyorsa üretimi planlar.
  static ui.Image? image(Size px) {
    if (px != _want) {
      _want = px;
      _settle?.cancel();
      // İlk görüntü beklemeden; sonraki boyut değişiklikleri durulunca.
      if (_img == null) {
        _render();
      } else {
        _settle = Timer(const Duration(milliseconds: 250), _render);
      }
    }
    return _img;
  }

  static Future<void> _render() async {
    if (_rendering || _want.isEmpty) return;
    _rendering = true;
    final px = _want;
    final prog = await _program;
    if (prog != null && px != _imgSize) {
      final sh = prog.fragmentShader()
        ..setFloat(0, px.width)
        ..setFloat(1, px.height)
        ..setFloat(2, 3.7);
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Offset.zero & px, Paint()..shader = sh);
      final pic = rec.endRecording();
      final img = await pic.toImage(px.width.toInt(), px.height.toInt());
      pic.dispose();
      sh.dispose();
      final old = _img;
      _img = img;
      _imgSize = px;
      ready.value++;
      // Eski görüntü bir sonraki karede artık çizilmez.
      SchedulerBinding.instance.addPostFrameCallback((_) => old?.dispose());
    }
    _rendering = false;
    if (_want != _imgSize && prog != null) _render();
  }
}

class _Star {
  _Star(math.Random r)
      : x = r.nextDouble(),
        y = r.nextDouble(),
        depth = 0.15 + 0.85 * math.pow(r.nextDouble(), 1.6),
        size = 0.6 + r.nextDouble() * 1.1,
        phase = r.nextDouble() * math.pi * 2,
        speed = 0.5 + r.nextDouble() * 1.5,
        cool = r.nextDouble() < 0.3;

  final double x, y, depth, size, phase, speed;
  final bool cool;
}

class _NebulaPainter extends CustomPainter {
  _NebulaPainter(this.s, this.dpr) : super(repaint: Listenable.merge([s._repaint, Sprites.ready]));

  final _AuroraBackgroundState s;
  final double dpr;

  /// Görüntü kenar payı (mantıksal px): paralaks ve süzülme kenarı açmasın.
  static const _margin = 24.0;

  static final _stars = () {
    final r = math.Random(3);
    return List.generate(240, (_) => _Star(r));
  }();
  static final _starXf = Float32List(_stars.length * 4);
  static final _starSrc = Float32List(_stars.length * 4);
  static final _starCol = Int32List(_stars.length);

  /// Dört köşeli parıltılar: (x, y, boy px, periyot s, faz).
  static const _sparkles = [
    (0.08, 0.14, 15.0, 6.2, 0.0),
    (0.91, 0.10, 20.0, 7.4, 1.3),
    (0.70, 0.27, 11.0, 5.1, 2.9),
    (0.04, 0.62, 13.0, 8.0, 4.1),
    (0.95, 0.55, 16.0, 6.8, 0.7),
    (0.27, 0.90, 18.0, 7.9, 2.2),
    (0.83, 0.92, 12.0, 5.6, 3.6),
    (0.47, 0.06, 10.0, 6.5, 5.0),
    (0.58, 0.95, 9.0, 5.3, 1.9),
  ];
  static final _spXf = Float32List(_sparkles.length * 4);
  static final _spSrc = Float32List(_sparkles.length * 4);
  static final _spCol = Int32List(_sparkles.length);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final t = s._clock.seconds;
    final full = rect.inflate(_margin);
    final dust = _Dust.image(Size((full.width * dpr).roundToDouble(), (full.height * dpr).roundToDouble()));
    if (dust == null || s.intensity < 0.999) canvas.drawRect(rect, Paint()..color = AppColors.bg);
    if (dust != null) {
      // Paralaks (imlece karşı) + yavaş süzülme; tam cihaz pikseline yuvarlanır, gren keskin kalır.
      final o = (s.glowPos - const Offset(0.5, 0.5)) * -14 + Offset(math.sin(t * 0.05) * 10, math.cos(t * 0.037) * 7);
      final shift = Offset((o.dx * dpr).roundToDouble() / dpr, (o.dy * dpr).roundToDouble() / dpr);
      canvas.drawImageRect(
        dust,
        Rect.fromLTWH(0, 0, dust.width.toDouble(), dust.height.toDouble()),
        full.shift(shift),
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Color.fromRGBO(255, 255, 255, s.intensity.clamp(0.0, 1.0)),
      );
    }

    // İmleç ışığı ve hover'daki kartın tonu tek ışıkta: imleçte sönük beyaz, kartın üstünde marka rengi.
    final a = 0.05 * s.glowAmt + 0.085 * s.tintAmt;
    if (a > 0.003) {
      final p = Offset(s.glowPos.dx * size.width, s.glowPos.dy * size.height);
      Sprites.paint(canvas, Sprites.glow, Rect.fromCircle(center: p, radius: size.shortestSide * (0.42 + 0.20 * s.tintAmt)),
          Color.lerp(const Color(0xFFE8ECF5), s.tint, s.tintAmt)!.withValues(alpha: a.clamp(0.0, 1.0)));
    }

    _paintStars(canvas, size, t);
    _paintSparkles(canvas, size, t);
  }

  /// Yıldızlar tek drawAtlas çağrısı (derinliğe göre boyut, parlaklık, paralaks, ışıldama).
  void _paintStars(Canvas canvas, Size size, double t) {
    final dot = Sprites.dot;
    if (dot == null) return;
    final par = s.glowPos - const Offset(0.5, 0.5);
    for (var i = 0; i < _stars.length; i++) {
      final st = _stars[i];
      final x = st.x * size.width - par.dx * 22 * st.depth;
      final y = ((st.y - t * 0.0022 * st.depth) % 1.0) * size.height - par.dy * 16 * st.depth;
      final px = st.size * (0.7 + 0.5 * st.depth) * 3.2;
      _starXf
        ..[i * 4] = px / dot.width
        ..[i * 4 + 1] = 0
        ..[i * 4 + 2] = x - px / 2
        ..[i * 4 + 3] = y - px / 2;
      _starSrc
        ..[i * 4 + 2] = dot.width.toDouble()
        ..[i * 4 + 3] = dot.height.toDouble();
      final tw = 0.55 + 0.45 * math.sin(t * st.speed + st.phase);
      final a = ((0.10 + 0.60 * st.depth * tw) * s.intensity).clamp(0.0, 1.0);
      final base = st.cool ? const Color(0xFFDCE4FF) : const Color(0xFFFFFFFF);
      _starCol[i] = base.withValues(alpha: a).toARGB32();
    }
    canvas.drawRawAtlas(dot, _starXf, _starSrc, _starCol, BlendMode.modulate, null,
        Paint()..filterQuality = FilterQuality.low);
  }

  /// Simgedeki gibi dört köşeli parıltılar: yavaş, farklı fazlarda ışıldar (tek drawAtlas).
  void _paintSparkles(Canvas canvas, Size size, double t) {
    final img = Sprites.sparkle;
    if (img == null) return;
    final par = s.glowPos - const Offset(0.5, 0.5);
    for (var i = 0; i < _sparkles.length; i++) {
      final (x, y, px, period, phase) = _sparkles[i];
      final tw = 0.5 + 0.5 * math.sin(t * 2 * math.pi / period + phase);
      final sz = px * (0.75 + 0.35 * tw);
      _spXf
        ..[i * 4] = sz / img.width
        ..[i * 4 + 1] = 0
        ..[i * 4 + 2] = x * size.width - par.dx * 26 - sz / 2
        ..[i * 4 + 3] = y * size.height - par.dy * 18 - sz / 2;
      _spSrc
        ..[i * 4 + 2] = img.width.toDouble()
        ..[i * 4 + 3] = img.height.toDouble();
      _spCol[i] = const Color(0xFFFFFFFF).withValues(alpha: ((0.18 + 0.50 * tw * tw) * s.intensity).clamp(0.0, 1.0)).toARGB32();
    }
    canvas.drawRawAtlas(img, _spXf, _spSrc, _spCol, BlendMode.modulate, null,
        Paint()
          ..blendMode = BlendMode.plus
          ..filterQuality = FilterQuality.low);
  }

  @override
  bool shouldRepaint(_NebulaPainter old) => old.dpr != dpr || old.s != s;
}
