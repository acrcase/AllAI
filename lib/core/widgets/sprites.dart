import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Önceden çizilmiş yumuşak şekiller (ışıltı, nokta, halka, şerit, dört köşeli parıltı), film greni ve küçük gradyan
/// görüntüleri. Ekran boyu ışımayı her karede gradyanla çizmek yerine hazır görüntü ölçeklenir.
///
/// Görüntüler yalnız eşzamansız `toImage` ile üretilir. Ölçüm (Intel UHD 630, Impeller): `toImageSync`
/// ile üretilen görüntüler karelerin bir kısmında ana ekranın hiç çizilmemesine ve yazı gliflerinin
/// bozulmasına yol açtı (Skia'da sorun yok). Yeni bir görüntü hazır olunca [ready] artar
/// (boyacılar `repaint:` ile dinler).
abstract final class Sprites {
  static ui.Image? _dot, _glow, _ring, _band, _sparkle, _grain;
  static Future<void>? _init;
  static final _gradients = <String, ui.Image>{};
  static final _pending = <String>{};

  /// Yeni bir görüntü hazır olunca artar.
  static final ready = ValueNotifier<int>(0);

  /// Impeller'da güvenli kip: çalışma anında üretilen görüntü sayısı en azda tutulur (kart önbelleği ve
  /// boyalı kopya yok; ışıltılar analitik bulanık şekil). Ölçüm (Intel UHD 630, Impeller MetalSDF):
  /// her karede çizilen bu tür görüntüler arttıkça karelerin %25–50'sinde ana ekran boş çıktı.
  /// Skia'da (FLTEnableImpeller=false) hızlı yol kullanılır.
  static final bool safe = ui.ImageFilter.isShaderFilterSupported;

  /// Beyaz, kenara doğru sönen nokta (parçacık, kıvılcım, yıldız).
  static ui.Image? get dot => _dot;

  /// Gauss'a yakın geniş ışık (imleç ışığı, parlama, hale).
  static ui.Image? get glow => _glow;

  /// İnce, yumuşak kenarlı halka (basınca ışık dalgası).
  static ui.Image? get ring => _ring;

  /// Yatay olarak sönen dikey şerit (ışık süpürmesi).
  static ui.Image? get band => _band;

  /// Dört köşeli parıltı yıldızı (simgedeki ışıltılar, zemindeki parıltılar).
  static ui.Image? get sparkle => _sparkle;

  /// 512 px film greni (gri gürültü, düşük alfa).
  static ui.Image? get grain => _grain;

  /// Bütün sprite'ları bir kez hazırlar (uygulama açılırken çağrılır; tekrar çağrı aynı işi bekler).
  static Future<void> init() => _init ??= _make();

  static Future<void> _make() async {
    _dot = await _radial(64, const [1, 0.55, 0.18, 0.04, 0], const [0, 0.22, 0.5, 0.75, 1]);
    _glow = await _radial(256, [for (var i = 0; i <= 8; i++) math.exp(-math.pow(i / 8 * 2.1, 2))], [
      for (var i = 0; i <= 8; i++) i / 8,
    ]);
    _ring = await _radial(256, const [0, 0, 0.35, 1, 0.35, 0], const [0, 0.72, 0.84, 0.92, 0.97, 1]);
    _band = await _draw(128, 32, (c, s) {
      c.drawRect(
        Offset.zero & s,
        Paint()
          ..shader = const LinearGradient(colors: [
            Color(0x00FFFFFF),
            Color(0x66FFFFFF),
            Color(0xFFFFFFFF),
            Color(0x66FFFFFF),
            Color(0x00FFFFFF),
          ], stops: [0, 0.3, 0.5, 0.7, 1]).createShader(Offset.zero & s),
      );
    });
    _sparkle = await _draw(64, 64, (c, s) {
      final o = s.center(Offset.zero);
      c.drawCircle(o, 12, Paint()
        ..shader = const RadialGradient(colors: [Color(0x99FFFFFF), Color(0x00FFFFFF)]).createShader(Rect.fromCircle(center: o, radius: 12)));
      // İnce, uca doğru incelen dört kol (yatay kollar biraz daha uzun).
      final arms = Path();
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi / 4;
        final r = i.isOdd ? 2.6 : (i % 4 == 0 ? 31.0 : 27.0);
        final p = o + Offset(math.cos(a), math.sin(a)) * r;
        i == 0 ? arms.moveTo(p.dx, p.dy) : arms.lineTo(p.dx, p.dy);
      }
      arms.close();
      c.drawPath(arms, Paint()
        ..color = const Color(0xFFFFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.9));
      c.drawCircle(o, 3.2, Paint()..color = const Color(0xFFFFFFFF));
    });
    _grain = await _makeGrain();
    ready.value++;
  }

  /// [gradient]'in küçük görüntüsü (ör. 128×80; büyütülünce yumuşak kalır). İlk istekte üretimi başlatır,
  /// hazır olana dek null döner.
  static ui.Image? gradient(String key, Gradient gradient, {int width = 96, int height = 64}) {
    final img = _gradients[key];
    if (img != null || _pending.contains(key)) return img;
    _pending.add(key);
    _draw(width, height, (c, s) {
      c.drawRect(Offset.zero & s, Paint()..shader = gradient.createShader(Offset.zero & s));
    }).then((img) {
      _gradients[key] = img;
      _pending.remove(key);
      ready.value++;
    });
    return null;
  }

  /// Beyaz [img]'i [color] ile boyayıp [dst]'ye çizer (renk süzgeci; renk gölgelendiricide tek değişken).
  /// Ölçüm (Intel UHD 630, Skia): eski yol her yeni renk için boyalı kopyayı `toImage` ile üretiyordu
  /// (4 bit/kanal); ilk hover'da ve kartlar arasında gezinirken ton renk geçişi yaptıkça raster iş
  /// parçacığında yeni kopyalar üretilip kareler uzuyordu. Impeller'da [_shape] kullanılır.
  static void paint(Canvas c, ui.Image? img, Rect dst, Color color,
      {double rotation = 0, BlendMode blend = BlendMode.srcOver}) {
    if (img == null || color.a <= 0.002 || dst.isEmpty) return;
    if (safe) return _shape(c, img, dst, color, rotation, blend);
    final paint = Paint()
      ..color = Color.fromRGBO(255, 255, 255, color.a)
      ..blendMode = blend
      ..filterQuality = FilterQuality.low
      ..colorFilter = ColorFilter.mode(color.withValues(alpha: 1), BlendMode.modulate);
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    if (rotation == 0) {
      c.drawImageRect(img, src, dst, paint);
      return;
    }
    c.save();
    c.translate(dst.center.dx, dst.center.dy);
    c.rotate(rotation);
    c.drawImageRect(img, src, Rect.fromCenter(center: Offset.zero, width: dst.width, height: dst.height), paint);
    c.restore();
  }

  /// Güvenli kipte sprite yerine aynı izlenimi veren bulanık şekil (dikdörtgen/yuvarlak bulanıklığı analitik).
  static void _shape(Canvas c, ui.Image img, Rect dst, Color color, double rotation, BlendMode blend) {
    final paint = Paint()
      ..color = color
      ..blendMode = blend;
    if (identical(img, _ring)) {
      final r = dst.shortestSide / 2 * 0.92;
      c.drawCircle(dst.center, r, paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.06
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.03 + 0.5));
      return;
    }
    if (identical(img, _band)) {
      c.save();
      c.translate(dst.center.dx, dst.center.dy);
      c.rotate(rotation);
      c.drawRect(Rect.fromCenter(center: Offset.zero, width: dst.width * 0.35, height: dst.height),
          paint..maskFilter = MaskFilter.blur(BlurStyle.normal, dst.width * 0.12));
      c.restore();
      return;
    }
    // Işık ve nokta: merkezde yoğun, kenara sönen hap/daire. Köşe yarıçapı dairesel ve tek: Impeller'ın
    // analitik bulanıklık yolu (eliptik köşe Gauss geçişine düşüyor).
    final core = identical(img, _dot) ? 0.22 : 0.18;
    final box = Rect.fromCenter(center: dst.center, width: dst.width * core * 2, height: dst.height * core * 2);
    final rr = RRect.fromRectAndRadius(box, Radius.circular(box.shortestSide / 2));
    c.drawRRect(rr, paint..maskFilter = MaskFilter.blur(BlurStyle.normal, dst.shortestSide * (identical(img, _dot) ? 0.12 : 0.16)));
  }

  static Future<ui.Image> _radial(int size, List<double> alphas, List<double> stops) => _draw(size, size, (c, s) {
        final r = Offset.zero & s;
        c.drawRect(
          r,
          Paint()
            ..shader = RadialGradient(
              colors: [for (final a in alphas) Color.fromRGBO(255, 255, 255, a)],
              stops: stops,
            ).createShader(r),
        );
      });

  static Future<ui.Image> _draw(int w, int h, void Function(Canvas c, Size s) body) async {
    final rec = ui.PictureRecorder();
    body(Canvas(rec), Size(w.toDouble(), h.toDouble()));
    final pic = rec.endRecording();
    final img = await pic.toImage(w, h);
    pic.dispose();
    return img;
  }

  static Future<ui.Image> _makeGrain() async {
    const n = 512;
    final rnd = math.Random(7);
    final px = Uint8List(n * n * 4);
    for (var i = 0; i < n * n; i++) {
      // Önçarpımlı: renk ≤ alfa. Alfa ≈ %4: görünür ama okunmaz, büyütülen gradyanın bantlarını örter.
      const a = 10;
      final v = (rnd.nextDouble() * a).round();
      px[i * 4] = v;
      px[i * 4 + 1] = v;
      px[i * 4 + 2] = v;
      px[i * 4 + 3] = a;
    }
    final buf = await ui.ImmutableBuffer.fromUint8List(px);
    final desc = ui.ImageDescriptor.raw(buf, width: n, height: n, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await desc.instantiateCodec();
    final img = (await codec.getNextFrame()).image;
    codec.dispose();
    return img;
  }
}
