import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'sprites.dart';

/// Kozmik işaretin geometrisi: uygulama simgesinin referans görüntüsü (`design/icon_reference.png`) üzerinden ölçüldü.
/// Birim: simge gövdesinin kenarı = 1; (0, 0) gövdenin sol üst köşesi. Açılıştaki parçalar ve
/// başlıktaki küçük işaret aynı sayılarla çizilir, görüntüden çizime geçiş fark edilmez.
abstract final class CosmicGeometry {
  /// Merkez yıldız ve koyu kürenin merkezi; kürenin parlak kenarının yarıçapı.
  static const star = Offset(0.500, 0.506);
  static const sphereR = 0.171;

  /// Satürn halkası: eğik elips. θ parametresi; sin θ > 0 yarısı (alt) kürenin önünden geçer.
  static const ringCenter = Offset(0.521, 0.519);
  static const ringA = 0.371, ringB = 0.104;
  static const ringTilt = -0.349; // -20°

  /// İnce yörüngeler: büyük eğik elips ve kürenin çevresindeki çember.
  static const orbitCenter = Offset(0.516, 0.474);
  static const orbitA = 0.439, orbitB = 0.235, orbitTilt = -0.419; // -24°
  static const innerOrbitR = 0.265;

  /// Dört köşeli parıltılar (yer, kol boyu), sarmal galaksiler, aylar (yer, yarıçap), yörünge boncukları.
  static const sparkles = [
    (Offset(0.775, 0.103), 0.060),
    (Offset(0.313, 0.869), 0.062),
    (Offset(0.142, 0.329), 0.040),
    (Offset(0.678, 0.916), 0.036),
    (Offset(0.109, 0.145), 0.024),
  ];
  static const galaxies = [Offset(0.241, 0.165), Offset(0.875, 0.723)];
  static const moons = [(Offset(0.860, 0.219), 0.027), (Offset(0.176, 0.818), 0.022), (Offset(0.810, 0.848), 0.020)];
  static const beads = [Offset(0.644, 0.167), Offset(0.589, 0.743), Offset(0.947, 0.526), Offset(0.092, 0.531), Offset(0.115, 0.584)];

  /// Eğik elips üzerindeki nokta.
  static Offset ellipse(Offset c, double a, double b, double tilt, double theta) {
    final x = math.cos(theta) * a, y = math.sin(theta) * b;
    final ct = math.cos(tilt), st = math.sin(tilt);
    return c + Offset(x * ct - y * st, x * st + y * ct);
  }

  static final _rc = math.cos(ringTilt), _rs = math.sin(ringTilt);

  /// Halkadaki nokta; [scale] halkayı kendi merkezi etrafında büyütür (açılışta kare başına binlerce kez:
  /// eğimin sinüs/kosinüsü önceden hesaplı).
  static Offset ring(double theta, [double scale = 1]) {
    final x = math.cos(theta) * ringA * scale, y = math.sin(theta) * ringB * scale;
    return Offset(ringCenter.dx + x * _rc - y * _rs, ringCenter.dy + x * _rs + y * _rc);
  }
}

/// Yumuşak kenarlı çizgi şeritleri (tek drawVertices). Her nokta üç tepe: kenarlar saydam, orta dolu;
/// ince çizgi kenar yumuşatmasız da pürüzsüz görünür.
class GlowStrips {
  final _pos = <double>[];
  final _col = <int>[];
  final _idx = <int>[];

  bool get isEmpty => _idx.isEmpty;

  /// [pts] boyunca [halfWidth] yarı genişlikte şerit; renk ve yarı genişlik noktaya göre değişebilir.
  void add(List<Offset> pts, double Function(int j) halfWidth, Color Function(int j) color) {
    if (pts.length < 2) return;
    final base = _pos.length ~/ 2;
    for (var j = 0; j < pts.length; j++) {
      final a = pts[math.max(0, j - 1)], b = pts[math.min(pts.length - 1, j + 1)];
      var d = b - a;
      final len = d.distance;
      d = len < 1e-6 ? const Offset(1, 0) : d / len;
      final n = Offset(-d.dy, d.dx) * halfWidth(j);
      final p = pts[j];
      final c = color(j);
      final clear = c.withValues(alpha: 0).toARGB32();
      _pos
        ..add(p.dx + n.dx)
        ..add(p.dy + n.dy)
        ..add(p.dx)
        ..add(p.dy)
        ..add(p.dx - n.dx)
        ..add(p.dy - n.dy);
      _col
        ..add(clear)
        ..add(c.toARGB32())
        ..add(clear);
      if (j == 0) continue;
      final q = base + (j - 1) * 3, r = base + j * 3;
      // Önceki ve bu noktanın üçlüsü arasında dört üçgen.
      _idx
        ..add(q)
        ..add(q + 1)
        ..add(r)
        ..add(q + 1)
        ..add(r + 1)
        ..add(r)
        ..add(q + 1)
        ..add(q + 2)
        ..add(r + 1)
        ..add(q + 2)
        ..add(r + 2)
        ..add(r + 1);
    }
  }

  void paint(Canvas c) {
    if (isEmpty) return;
    c.drawVertices(
      ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(_pos),
          colors: Int32List.fromList(_col), indices: Uint16List.fromList(_idx)),
      BlendMode.dst,
      Paint()..blendMode = BlendMode.plus,
    );
  }
}

/// Küçük ama dolgun kozmik işaret (başlık logosu): hacimli koyu küre + kalın parlak jant, kalın eğik halka
/// (arka yarısı sönük, ön yarısı kürenin önünde, ışımalı), ışınlı yıldız çekirdeği, hale; halkanın ön
/// yarısında yavaşça dolaşan ışık.
abstract final class CosmicMark {
  /// [center] yıldızın yeri, [side] gövde kenarı (işaret yaklaşık 0,74·side genişliğinde), [t] saniye.
  static void paint(Canvas c, Offset center, double side, {double t = 0}) {
    Offset p(Offset g) => center + (g - CosmicGeometry.star) * side;
    final rc = p(CosmicGeometry.ringCenter);
    Path ring(double k, [bool frontOnly = false]) {
      final rect = Rect.fromCenter(center: Offset.zero, width: CosmicGeometry.ringA * 2 * side * k, height: CosmicGeometry.ringB * 2 * side * k);
      final m = Float64List(16)
        ..[0] = math.cos(CosmicGeometry.ringTilt)
        ..[1] = math.sin(CosmicGeometry.ringTilt)
        ..[4] = -math.sin(CosmicGeometry.ringTilt)
        ..[5] = math.cos(CosmicGeometry.ringTilt)
        ..[10] = 1
        ..[12] = rc.dx
        ..[13] = rc.dy
        ..[15] = 1;
      return (frontOnly ? (Path()..addArc(rect, 0, math.pi)) : (Path()..addOval(rect))).transform(m);
    }

    final w = math.max(1.4, side * 0.05);
    Paint stroke(double width, Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width
      ..color = color;
    final sc = center;
    final r = CosmicGeometry.sphereR * side;
    final tw = 0.5 + 0.5 * math.sin(t * 1.7);

    // Hale ve arka yarı (küre önündeki kısmı örtecek).
    Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: sc, radius: r * 2.8), const Color(0xFFFFFFFF).withValues(alpha: 0.16));
    c.drawPath(ring(1), stroke(w * 2.6, const Color(0x1FFFFFFF)));
    c.drawPath(ring(1), stroke(w, const Color(0x8CFFFFFF)));
    c.drawPath(ring(0.88), stroke(w * 0.55, const Color(0x40FFFFFF)));
    // Küre: koyu iç gradyan, jantın iç ışığı, kalın parlak jant + ışıma.
    c.drawCircle(sc, r, Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFF050508), Color(0xFF0B0B10), Color(0xFF2A2A33), Color(0xFFCFCFD8)],
        stops: [0, 0.62, 0.86, 1],
      ).createShader(Rect.fromCircle(center: sc, radius: r)));
    Sprites.paint(c, Sprites.ring, Rect.fromCircle(center: sc, radius: r * 1.12 / 0.92), const Color(0xFFFFFFFF).withValues(alpha: 0.55),
        blend: BlendMode.plus);
    c.drawCircle(sc, r, stroke(w * 0.85, const Color(0xFFFFFFFF)));
    // Çekirdek: ışınlı yıldız, yavaş ışıldar.
    Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: sc, radius: r * (0.95 + 0.15 * tw)),
        const Color(0xFFFFFFFF).withValues(alpha: 0.7 + 0.2 * tw), blend: BlendMode.plus);
    Sprites.paint(c, Sprites.sparkle, Rect.fromCircle(center: sc, radius: r * (0.95 + 0.1 * tw)), const Color(0xFFFFFFFF).withValues(alpha: 0.85),
        blend: BlendMode.plus);
    c.drawCircle(sc, r * 0.2, Paint()..color = const Color(0xFFFFFFFF));
    // Ön yarı: geniş ışıma + kalın parlak çizgi + içte ikinci bant.
    c.drawPath(ring(1, true), stroke(w * 3, const Color(0x33FFFFFF)));
    c.drawPath(ring(1, true), stroke(w, const Color(0xFFFFFFFF)));
    c.drawPath(ring(0.88, true), stroke(w * 0.55, const Color(0x8CFFFFFF)));
    // Ön yarıda dolaşan ışık (~7 sn'de bir tur; arka yarıda görünmez).
    final th = (t / 7.0 % 1.0) * 2 * math.pi;
    final s = math.sin(th);
    if (s > 0) {
      Sprites.paint(c, Sprites.dot, Rect.fromCircle(center: p(CosmicGeometry.ring(th)), radius: side * 0.09),
          const Color(0xFFFFFFFF).withValues(alpha: 0.95 * s), blend: BlendMode.plus);
    }
  }
}
