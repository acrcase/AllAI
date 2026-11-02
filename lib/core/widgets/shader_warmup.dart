import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'sprites.dart';

/// Gölgelendirici ısındırma. Skia arka ucunda her çizim türü ilk kullanıldığı karede derlenir
/// (ölçüm: açılışın ilk karelerinde 200–450 ms, ilk hover'da 18–40 ms takılma). Açılışta ve ana ekranda
/// kullanılan türlerin hepsi görünmeyen küçük bir resme bir kez çizilir; açılış bu bitince başlar
/// (ekran o sırada siyah). Hover'daki kart 3B perspektifle çizildiği için kartın bütün katmanları
/// (önbellek görüntüsü, konik kenar, ışıltılar, kırpma, yazı, simge) perspektif altında da çizilir.
/// Impeller'da boru hatları önceden hazır olduğundan birkaç ms'de biter.
Future<void> warmUpShaders() async {
  await Sprites.init();
  // Gölgelendirici → kayan nokta sayısı (bkz. .frag uniform'ları).
  const uniforms = {'shaders/nebula.frag': 3};
  final programs = await Future.wait([
    for (final e in uniforms.entries)
      ui.FragmentProgram.fromAsset(e.key).then<(ui.FragmentProgram, int)?>((p) => (p, e.value), onError: (_) => null),
  ]);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  const r = Rect.fromLTWH(0, 0, 48, 48);
  final rr = RRect.fromRectAndRadius(r, const Radius.circular(8));
  const colors = [Color(0xFFC9CFDA), Color(0x0010A37F)];

  c.drawRect(r, Paint()..shader = const LinearGradient(colors: colors).createShader(r));
  c.drawRect(r, Paint()..shader = const LinearGradient(colors: colors, stops: [0.2, 0.8]).createShader(r));
  c.drawRect(r, Paint()..shader = const RadialGradient(colors: colors).createShader(r));
  c.drawRRect(
    rr,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..shader = SweepGradient(colors: colors, transform: const GradientRotation(1)).createShader(r),
  );
  c.drawCircle(const Offset(24, 24), 20, Paint()..shader = const SweepGradient(colors: colors).createShader(r));
  for (final s in const [4.0, 14.0]) {
    c.drawRRect(rr, Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, s));
    c.drawCircle(const Offset(24, 24), 10, Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, s));
  }
  // Kozmik işaret: eğik elips ve yay çizgileri (yuvarlak uçlu), çember kenarı.
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1.5
    ..color = const Color(0xCCFFFFFF);
  final oval = Path()..addOval(const Rect.fromLTWH(4, 18, 40, 12));
  c.drawPath(oval.transform(_rotation(-0.35)), stroke);
  c.drawPath((Path()..addArc(const Rect.fromLTWH(4, 18, 40, 12), 0, math.pi)).transform(_rotation(-0.35)), stroke);
  c.drawCircle(const Offset(24, 24), 8, stroke);
  // Görüntüler: alfa, toplamalı karışım, renk süzgeci, kırpma, perspektif.
  final img = Sprites.glow!;
  final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
  for (final b in const [BlendMode.srcOver, BlendMode.plus]) {
    for (final q in const [FilterQuality.none, FilterQuality.low, FilterQuality.medium]) {
      c.drawImageRect(img, src, r, Paint()
        ..blendMode = b
        ..filterQuality = q
        ..color = const Color(0x80FFFFFF));
    }
  }
  // Sprites.paint: renk süzgeci + alfa, düz ve toplamalı karışım.
  for (final b in const [BlendMode.srcOver, BlendMode.plus]) {
    c.drawImageRect(img, src, r, _tinted(b));
  }
  c.save();
  c.translate(24, 24);
  c.rotate(-0.35);
  c.drawImageRect(img, src, const Rect.fromLTWH(-20, -8, 40, 16), _tinted(BlendMode.plus));
  c.restore();
  c.save();
  c.clipRRect(rr);
  c.drawImageRect(img, src, r, Paint()..blendMode = BlendMode.plus);
  c.restore();
  // Hover'daki kart: perspektif altında kartın bütün katmanları.
  c.save();
  c.transform(_perspective());
  _tileLayers(c, img, src, r, rr, colors);
  c.restore();
  // Atlas, üçgenler (indisli ve indissiz), noktalar.
  final dot = Sprites.dot!;
  for (final a in [dot, Sprites.sparkle!]) {
    c.drawRawAtlas(a, Float32List.fromList([0.5, 0, 4, 4, 0.3, 0, 20, 20]), Float32List.fromList([0, 0, 64, 64, 0, 0, 64, 64]),
        Int32List.fromList([0xCCC9CFDA, 0x8810A37F]), BlendMode.modulate, null, Paint()..blendMode = BlendMode.plus);
  }
  c.drawRawAtlas(dot, Float32List.fromList([0.5, 0, 4, 4]), Float32List.fromList([0, 0, 64, 64]), Int32List.fromList([0xCCFFFFFF]),
      BlendMode.modulate, null, Paint()..filterQuality = FilterQuality.low);
  c.drawVertices(
    ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList([0, 0, 40, 4, 8, 40]),
        colors: Int32List.fromList([0xFFFFFFFF, 0xFFC9CFDA, 0x00000000])),
    BlendMode.dst,
    Paint()..blendMode = BlendMode.plus,
  );
  c.drawVertices(
    ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList([0, 0, 40, 4, 8, 40, 30, 30]),
        colors: Int32List.fromList([0xFFFFFFFF, 0xFFC9CFDA, 0x00000000, 0x80FFFFFF]), indices: Uint16List.fromList([0, 1, 2, 1, 3, 2])),
    BlendMode.dst,
    Paint()..blendMode = BlendMode.plus,
  );
  // Açılışın kırık parçaları: dokulu, tepe renkli üçgenler (ImageShader + modulate).
  c.drawVertices(
    ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList([0, 0, 40, 4, 8, 40, 30, 30]),
        textureCoordinates: Float32List.fromList([0, 0, 200, 20, 40, 200, 150, 150]),
        colors: Int32List.fromList([0xFFFFFFFF, 0xCCFFFFFF, 0x80C9CFDA, 0xFFFFFFFF]),
        indices: Uint16List.fromList([0, 1, 2, 1, 3, 2])),
    BlendMode.modulate,
    Paint()..shader = ImageShader(img, TileMode.clamp, TileMode.clamp, Float64List.fromList(_identity), filterQuality: FilterQuality.low),
  );
  c.drawRawPoints(ui.PointMode.points, Float32List.fromList([10, 10, 30, 30]), Paint()
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 2
    ..color = const Color(0xAAFFFFFF));
  // Katman + maske ve gradyanlı yazı (başlık logosu).
  c.saveLayer(r, Paint()..color = const Color(0xCCFFFFFF));
  final tp = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: 'AllAI',
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        foreground: Paint()..shader = const LinearGradient(colors: colors).createShader(r),
      ),
    ),
  )..layout();
  tp.paint(c, Offset.zero);
  tp.dispose();
  c.drawRect(r, Paint()
    ..blendMode = BlendMode.dstIn
    ..shader = const LinearGradient(colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)]).createShader(r));
  c.restore();
  c.drawRect(r, Paint()
    ..color = const Color(0x80FFFFFF)
    ..blendMode = BlendMode.plus);
  // Özel gölgelendirici (zemin tozu).
  for (final e in programs) {
    if (e == null) continue;
    final sh = e.$1.fragmentShader();
    for (var i = 0; i < e.$2; i++) {
      sh.setFloat(i, i < 2 ? 48 : 0.5);
    }
    c.drawRect(r, Paint()..shader = sh);
  }
  final pic = rec.endRecording();
  final out = await pic.toImage(48, 48); // raster iş parçacığı derlemeyi bitirene dek bekler
  pic.dispose();
  out.dispose();
}

/// Kartın katmanları (bkz. ai_tile.dart): önbellek görüntüsü (alfalı), konik kenar + hale çizgileri,
/// kırpılmış toplamalı ışıltılar, karartma örtüsü, yazı, simge.
void _tileLayers(Canvas c, ui.Image img, Rect src, Rect r, RRect rr, List<Color> colors) {
  for (final q in const [FilterQuality.low, FilterQuality.medium]) {
    c.drawImageRect(img, src, r, Paint()
      ..filterQuality = q
      ..color = const Color(0x99FFFFFF));
  }
  final sweep = SweepGradient(colors: colors, transform: const GradientRotation(0.4)).createShader(r);
  for (final w in const [1.6, 4.5]) {
    c.drawRRect(rr, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..shader = sweep
      ..color = const Color(0x80FFFFFF));
  }
  c.drawImageRect(Sprites.dot!, const Rect.fromLTWH(0, 0, 64, 64), const Rect.fromLTWH(4, 4, 10, 10), _tinted(BlendMode.plus));
  c.save();
  c.clipRRect(rr);
  c.drawImageRect(img, src, r, _tinted(BlendMode.srcOver));
  c.drawImageRect(img, src, r, _tinted(BlendMode.plus));
  c.drawImageRect(img, src, r, Paint()
    ..color = const Color(0x40FFFFFF)
    ..filterQuality = FilterQuality.low);
  c.drawImageRect(Sprites.band!, Rect.fromLTWH(0, 0, Sprites.band!.width.toDouble(), Sprites.band!.height.toDouble()), r,
      Paint()..color = const Color(0x20FFFFFF));
  c.restore();
  c.drawRRect(rr, Paint()..color = const Color(0x40000000));
  final tp = TextPainter(
    textDirection: TextDirection.ltr,
    text: const TextSpan(text: 'ChatGPT', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFFF4F5FA))),
  )..layout();
  tp.paint(c, const Offset(2, 20));
  tp.dispose();
}

const _identity = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

Paint _tinted(BlendMode b) => Paint()
  ..blendMode = b
  ..filterQuality = FilterQuality.low
  ..color = const Color(0x80FFFFFF)
  ..colorFilter = const ColorFilter.mode(Color(0xFF10A37F), BlendMode.modulate);

/// Eğik elips için döndürme (orta noktası 24,24), sütun öncelikli.
Float64List _rotation(double a) {
  final m = Float64List(16);
  m[0] = math.cos(a);
  m[1] = math.sin(a);
  m[4] = -math.sin(a);
  m[5] = math.cos(a);
  m[10] = 1;
  m[12] = 24 - 24 * math.cos(a) + 24 * math.sin(a);
  m[13] = 24 - 24 * math.sin(a) - 24 * math.cos(a);
  m[15] = 1;
  return m;
}

/// Perspektifli küçük bir dönüşüm (3B eğilen kartın boru hattı için), sütun öncelikli.
Float64List _perspective() {
  final m = Float64List(16);
  m[0] = math.cos(0.1);
  m[2] = -math.sin(0.1);
  m[5] = 1;
  m[8] = math.sin(0.1);
  m[10] = math.cos(0.1);
  m[11] = 0.0011;
  m[15] = 1;
  return m;
}
