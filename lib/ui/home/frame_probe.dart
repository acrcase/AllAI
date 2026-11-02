import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

import '../../core/motion.dart';

/// Kare süresi ölçümü. Yalnız profil/hata ayıklama derlemesinde ve `ALLAI_PROBE=1` ile çalışır:
/// sahte fare olaylarıyla (gerçek imleç oynatılmaz) boşta / ilk hover / hover / gezinme / sürükleme /
/// büyüme / küçülme evrelerini oynatır, her evrenin UI (build) ve raster sürelerini yazdırır
/// (p50/p95/p99/en kötü), sonra uygulamayı kapatır.
/// `SHOT <ad>` satırları dışarıdaki betiğin ekran görüntüsü alacağı anları işaretler.
class FrameProbe {
  FrameProbe._();

  static bool get enabled => !kReleaseMode && Platform.environment['ALLAI_PROBE'] == '1';

  static const _device = 917; // gerçek fareyle karışmasın
  static String _phase = 'acilis';
  static final _data = <String, List<FrameTiming>>{};
  static final _spans = <String, Duration>{};
  static final _clock = Stopwatch();

  static void start() {
    _clock.start();
    SchedulerBinding.instance.addTimingsCallback((t) => _data.putIfAbsent(_phase, () => []).addAll(t));
  }

  /// Dışarıdan evre değiştirme (ör. açılış ısınmayı bitirip oynamaya başladı).
  static void enter(String p) {
    if (enabled && _clock.isRunning) _enter(p);
  }

  static void _enter(String p) {
    _spans[_phase] = (_spans[_phase] ?? Duration.zero) + _clock.elapsed;
    _clock.reset();
    _phase = p;
  }

  static Future<void> _wait(int ms) => Future.delayed(Duration(milliseconds: ms));

  static void _say(String s) => stdout.writeln(s);

  static void _ptr(PointerEvent e) => GestureBinding.instance.handlePointerEvent(e);

  /// Fareyi [from] → [to] arası [ms] boyunca 8 ms aralıkla sürer; [path] verilirse onu izler.
  static Future<void> _move(Offset Function(double t) path, int ms, {bool down = false}) async {
    final sw = Stopwatch()..start();
    var last = path(0);
    while (sw.elapsedMilliseconds < ms) {
      await _wait(8);
      final p = path((sw.elapsedMilliseconds / ms).clamp(0.0, 1.0));
      _ptr(down
          ? PointerMoveEvent(device: _device, kind: PointerDeviceKind.mouse, position: p, delta: p - last, buttons: kPrimaryMouseButton)
          : PointerHoverEvent(device: _device, kind: PointerDeviceKind.mouse, position: p, delta: p - last));
      last = p;
    }
  }

  /// [tile] i'inci kartın ekrandaki yeri; [dive] kartı büyütüp geri küçültür (görüntüleyici açılmaz).
  static Future<void> run({
    required Future<void> introDone,
    required Rect? Function(int i) tile,
    required Future<void> Function(int i) dive,
    required int count,
  }) async {
    await introDone;
    _enter('acilis-sonrasi');
    await _wait(1200);
    _enter('bosta');
    await _wait(1500);
    _say('SHOT bosta');
    await _wait(4500);

    final a = tile(0), b = tile(math.min(1, count - 1));
    if (a == null || b == null) return _finish();
    _ptr(PointerAddedEvent(device: _device, kind: PointerDeviceKind.mouse, position: a.topLeft - const Offset(20, 20)));
    // İlk hover ayrı: ilk kullanımda gölgelendirici derleme takılması burada görünür.
    _enter('ilk-hover');
    await _move((t) => Offset.lerp(a.topLeft - const Offset(20, 20), a.center, t)!, 300);
    await _wait(500);
    _enter('hover');
    // Kartın içinde daire çiz (eğilme + imleç ışığı + kıvılcım).
    await _move((t) {
      final ang = t * math.pi * 4;
      return a.center + Offset(math.cos(ang) * a.width * 0.3, math.sin(ang) * a.height * 0.3);
    }, 1200);
    _say('SHOT hover');
    await _move((t) {
      final ang = math.pi * 4 + t * math.pi * 4;
      return a.center + Offset(math.cos(ang) * a.width * 0.3, math.sin(ang) * a.height * 0.3);
    }, 1800);
    // Kartlar arasında hızlı gezin (her kartta ~260 ms; ileri ve geri).
    _enter('gezinme');
    final rects = [for (var i = 0; i < count; i++) tile(i)].whereType<Rect>().toList();
    final tour = [...rects, ...rects.reversed.skip(1)];
    for (var k = 0; k + 1 < tour.length; k++) {
      await _move((t) => Offset.lerp(tour[k].center, tour[k + 1].center, t)!, 260);
    }
    _enter('surukleme');
    final start = b.center;
    _ptr(PointerHoverEvent(device: _device, kind: PointerDeviceKind.mouse, position: start));
    await _wait(60);
    _ptr(PointerDownEvent(device: _device, kind: PointerDeviceKind.mouse, position: start, buttons: kPrimaryMouseButton));
    await _move((t) {
      final ang = t * math.pi * 2;
      final r = math.min(1.0, t * 6) * 160;
      return start + Offset(math.sin(ang) * r, (1 - math.cos(ang)) * r * 0.5);
    }, 2400, down: true);
    _say('SHOT surukleme');
    await _move((t) => start, 300, down: true);
    _ptr(PointerUpEvent(device: _device, kind: PointerDeviceKind.mouse, position: start));
    await _wait(500);
    // Fareyi pencereden çıkar.
    _ptr(PointerHoverEvent(device: _device, kind: PointerDeviceKind.mouse, position: const Offset(-50, -50)));
    _ptr(const PointerRemovedEvent(device: _device, kind: PointerDeviceKind.mouse));
    await _wait(400);

    // Büyüme (kart → içerik alanı, kısa bekleme dahil) ve küçülme (ana ekrana dönüş) ayrı ölçülür.
    for (var k = 0; k < 3; k++) {
      _enter('buyume');
      if (k == 0) Future.delayed(const Duration(milliseconds: 170), () => _say('SHOT buyume'));
      final done = dive(k % math.max(1, count));
      await _wait(Motion.expand.inMilliseconds + 150);
      _enter('kuculme');
      await done;
      await _wait(250);
    }
    _enter('son');
    await _wait(600);
    _finish();
  }

  static void _finish() {
    _enter('son');
    _say('PROBE evre | kare | süre s | fps | UI p50/p95/p99/max ms | raster p50/p95/p99/max ms | >16.7ms | >33ms');
    for (final MapEntry(key: name, value: list) in _data.entries) {
      if (list.isEmpty || name == 'son') continue;
      double ms(Duration d) => d.inMicroseconds / 1000;
      String q(List<double> v) {
        v.sort();
        double at(double p) => v[((v.length - 1) * p).round()];
        return '${at(0.5).toStringAsFixed(1)}/${at(0.95).toStringAsFixed(1)}/${at(0.99).toStringAsFixed(1)}/${v.last.toStringAsFixed(1)}';
      }

      final ui = [for (final f in list) ms(f.buildDuration)];
      final raster = [for (final f in list) ms(f.rasterDuration)];
      int over(double lim) => list.where((f) => ms(f.buildDuration) > lim || ms(f.rasterDuration) > lim).length;
      final span = (_spans[name] ?? Duration.zero).inMilliseconds / 1000;
      final fps = span > 0 ? (list.length / span).toStringAsFixed(0) : '-';
      _say('PROBE $name | ${list.length} | ${span.toStringAsFixed(1)} | $fps | ${q(ui)} | ${q(raster)} | ${over(16.7)} | ${over(33.4)}');
    }
    exit(0);
  }
}
