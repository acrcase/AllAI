import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../motion.dart';

/// Zemin akışı ve boşta hareketler (simge nefesi, logo) için ortak, düşük hızlı saat.
///
/// En fazla [Motion.ambientHz] kez bildirir: boşta uygulama 30 karede kalır. Kullanan yoksa
/// ya da uygulama öne değilken (başka uygulama etkin, pencere gizli) durur; [seconds] o sürede ilerlemez.
class AmbientClock extends ChangeNotifier {
  AmbientClock._() {
    _life = AppLifecycleListener(onStateChange: (s) {
      _active = s == AppLifecycleState.resumed;
      _sync();
    });
  }

  static final instance = AmbientClock._();

  late final AppLifecycleListener _life;
  late final Ticker _ticker = Ticker(_tick, debugLabel: 'ambient');
  bool _active = true;
  int _users = 0;
  double _base = 0; // önceki çalışma dilimlerinden biriken süre
  double _seconds = 0;
  double _lastNotify = -1;

  double get seconds => _seconds;

  /// Yalnız test: saati sıfırlar (logo gibi saate bağlı çizimlerin golden'ı kararlı olsun).
  @visibleForTesting
  void debugReset() {
    _base = 0;
    _seconds = 0;
  }

  void attach() {
    _users++;
    _sync();
  }

  void detach() {
    _users--;
    _sync();
  }

  void _sync() {
    final run = _users > 0 && _active;
    if (run && !_ticker.isActive) {
      _base = _seconds;
      _lastNotify = -1;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration e) {
    final t = _base + e.inMicroseconds / 1e6;
    // 60 Hz vsync'te her ikinci kare; küçük pay, kare zamanlaması titrese de 30'dan aşağı düşmesin.
    if (_lastNotify >= 0 && t - _lastNotify < 1 / Motion.ambientHz - 0.004) return;
    _lastNotify = t;
    _seconds = t;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _life.dispose();
    super.dispose();
  }
}

/// Yeniden çizim tetikleyicisi (CustomPainter `repaint:` için).
class Pulse extends ChangeNotifier {
  void ping() => notifyListeners();
}
