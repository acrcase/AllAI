import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Kurulu bir macOS uygulamasının penceresini bizim pencerenin içine yerleştirir.
///
/// SÖZLEŞME (lib/ui/viewer/dock_pane.dart bunlara dayanır).
enum DockState { idle, launching, docked, needsPermission, notInstalled, failed }

class DockEvent {
  const DockEvent(this.type, {this.key, this.bundleId, this.message});

  /// Olayın ait olduğu kart ([AppDock.dock] çağrısındaki `key`).
  final String? key;

  /// 'docked' | 'terminated' | 'windowLost' | 'fullscreenUnsupported' | 'error' |
  /// 'coverOn' | 'coverOff' | 'closeBlocked': sürükleme / canlı boyutlanma boyunca delik örtülmeli
  /// (hedef altta yerine otururken kayma görünmesin); 'coverOff' hedef son yerine oturunca gelir.
  /// 'closeBlocked': kapatılan Chrome penceresi bir soruyla ("Sayfadan ayrıl?") durdu, öne alındı.
  final String type;
  final String? bundleId;
  final String? message;

  /// 'error' olayında Swift sabit kod (`err.xxx`) gönderir; ekrana dile göre çevrilmiş hâli.
  /// Tanınmayan metin olduğu gibi döner (eski/ham mesajlara geriye uyum).
  String? get localizedMessage {
    final m = message;
    if (m == null || !m.startsWith('err.')) return m;
    final key = 'native.$m';
    final text = t(key);
    return text == key ? m : text;
  }

  @override
  String toString() => 'DockEvent($type, $key, $bundleId, $message)';
}

class AppDock {
  AppDock._();
  static final instance = AppDock._();

  static const _channel = MethodChannel('allai/dock');
  static const _eventChannel = EventChannel('allai/dock/events');

  bool get isSupported => Platform.isMacOS;

  /// Erişilebilirlik izni var mı? [prompt] true ise sistem iletişim kutusunu açar.
  Future<bool> isTrusted({bool prompt = false}) async =>
      await _invoke<bool>('isTrusted', {'prompt': prompt}) ?? false;

  /// Sistem Ayarları > Gizlilik > Erişilebilirlik'i açar.
  Future<void> openAccessibilitySettings() => _invoke<void>('openAccessibilitySettings');

  Future<bool> isInstalled(String bundleId) async =>
      await _invoke<bool>('isInstalled', {'bundleId': bundleId}) ?? false;

  /// Uygulamayı açar (gerekirse), ana penceresini [rect] alanına oturtur.
  /// [key]: kartın kimliği; aynı uygulamanın birden çok örneği (ikinci hesap) bununla ayrılır.
  /// [separateProfile]: uygulama kendi veri klasörüyle ayrı bir örnek olarak açılır (ikinci hesap).
  /// [rect]: Flutter mantıksal koordinatı, pencere içeriğinin sol üstüne göre.
  /// Sonra başka bir dock/hide çağrısı gelirse [DockState.idle] döner (vazgeçildi).
  Future<DockState> dock(String key, String bundleId, Rect rect, {bool separateProfile = false}) async {
    if (!kReleaseMode) await _debugHooks();
    final state = await _invoke<String>('dock', {
      'key': key,
      'bundleId': bundleId,
      'separateProfile': separateProfile || _debugEnv['ALLAI_DOCK_PROFILE'] == '1',
      ..._rect(rect),
    });
    return DockState.values.asNameMap()[state] ?? DockState.failed;
  }

  /// Web kartlarının açıldığı tarayıcı (bkz. [dockWeb]).
  static const chromeBundleId = 'com.google.Chrome';

  /// macOS'ta Chrome kurulu mu: kuruluysa web kartları yerleşik görünüm yerine [dockWeb] ile açılır.
  Future<bool> webInChrome() async => await _invoke<bool>('webInChrome') ?? false;

  /// Web kartını sahibin Chrome'unda `--app` penceresiyle açıp [rect] alanına oturtur (oturum Chrome'un,
  /// çerez okunmaz). Chrome süreci sahibin: yalnız bu pencere bizim. Gizlenince ekran dışına taşınır,
  /// [close] onu kapatma düğmesiyle kapatır, Chrome açık kalır. Sahip pencereyi kapatırsa 'terminated' gelir.
  Future<DockState> dockWeb(String key, String url, Rect rect) async {
    if (!kReleaseMode) await _debugHooks();
    final state = await _invoke<String>('dockWeb', {'key': key, 'url': url, ..._rect(rect)});
    return DockState.values.asNameMap()[state] ?? DockState.failed;
  }

  /// Sekme kapatıldı: yerleşimi bırakır; uygulamayı AllAI açtıysa kapatır,
  /// önceden açıksa eski çerçevesine geri koyup gizler. Chrome penceresiyse yalnız o pencere kapanır.
  Future<void> close(String key) => _invoke<void>('close', {'key': key});

  /// Uygulama ayrı veri klasörüyle ikinci örnek olarak açılabiliyor mu (Electron uygulamaları).
  Future<bool> supportsProfiles(String bundleId) async =>
      await _invoke<bool>('supportsProfiles', {'bundleId': bundleId}) ?? false;

  /// İkinci hesap kartı kaldırıldı: örneği kapatır ve veri klasörünü siler. Örnek 5 sn içinde
  /// kapanmazsa döner ama klasör süreç bitince silinir (kapanırken çerez yazan Electron'a karşı).
  Future<void> deleteProfile(String key) => _invoke<void>('deleteProfile', {'key': key});

  /// Alan değişti (pencere boyutu, düzen). [Rect.zero]: delik yok, tıklama geçişi kapanır
  /// (ör. deliğin üstüne diyalog/menü çizilirken).
  Future<void> updateRect(Rect rect) => _invoke<void>('updateRect', _rect(rect));

  /// Yerleştirmeyi bırakır ve uygulamayı gizler (ana ekrana dönüş).
  /// [keep]: başka bir kart hemen yerleşecek; eski uygulama o yerleşene kadar görünür kalır (boş delik yok).
  Future<void> hide({bool keep = false}) => _invoke<void>('hide', {'keep': keep});

  /// Yalnız profil/hata ayıklama: denemeler sahibin açık uygulamalarına dokunmasın.
  /// ALLAI_DOCK_PROFILE=1 her uygulama kartını ayrı profille açar, ALLAI_PROFILES_DIR profil kökünü
  /// değiştirir, ALLAI_DRAGTEST=1 yerleşince pencereyi programla sürükler (gecikme ölçümü).
  static Map<String, String> get _debugEnv => kReleaseMode ? const {} : Platform.environment;
  bool _debugSent = false;

  Future<void> _debugHooks() async {
    final env = _debugEnv;
    if (_debugSent || !env.keys.any((k) => k.startsWith('ALLAI_'))) return;
    _debugSent = true;
    await _invoke<void>('debugHooks', {
      'profilesDir': env['ALLAI_PROFILES_DIR'],
      'dragTest': env['ALLAI_DRAGTEST'] == '1',
    });
  }

  bool _instanceTested = false;

  /// Yalnız profil/hata ayıklama (ALLAI_INSTANCETEST=1): aynı uygulamanın ikinci profil örneğine geçip
  /// döner, onu kapatır ve siler; [webUrl] verilirse Chrome penceresini gizler, geri getirir, kapatır.
  /// Adımlar stdout'a yazılır; sonuç dışarıdan pid ve pencereyle doğrulanır.
  Future<void> debugInstanceTest(String key, String bundleId, Rect rect, {String? webUrl}) async {
    if (_debugEnv['ALLAI_INSTANCETEST'] != '1' || _instanceTested) return;
    _instanceTested = true;
    Future<void> step(String name, Future<Object?> Function() run) async {
      await Future<void>.delayed(const Duration(seconds: 4));
      debugPrint('INSTANCETEST ${DateTime.now().toIso8601String()} $name: ${await run()}');
    }

    if (webUrl != null) {
      // Sürükleme denemesi de açıksa (yerleşimden 4 sn sonra, ~6 sn sürer) bitmesi beklenir.
      if (_debugEnv['ALLAI_DRAGTEST'] == '1') await Future<void>.delayed(const Duration(seconds: 8));
      await step('hide', () => hide().then((_) => 'ok'));
      await step('dockWeb $key', () => dockWeb(key, webUrl, rect));
      await step('close $key', () => close(key).then((_) => 'ok'));
      debugPrint('INSTANCETEST bitti');
      return;
    }
    const second = 'instance-test-2';
    await step('dock $second', () => dock(second, bundleId, rect, separateProfile: true));
    await step('dock $key', () => dock(key, bundleId, rect));
    await step('close $second', () => close(second).then((_) => 'ok'));
    await step('deleteProfile $second', () => deleteProfile(second).then((_) => 'ok'));
    debugPrint('INSTANCETEST bitti');
  }

  late final Stream<DockEvent> events = isSupported
      ? _eventChannel.receiveBroadcastStream().map(_toEvent)
      : const Stream.empty();

  static DockEvent _toEvent(dynamic raw) {
    final map = Map<String, Object?>.from(raw as Map);
    return DockEvent(
      map['type'] as String? ?? 'error',
      key: map['key'] as String?,
      bundleId: map['bundleId'] as String?,
      message: map['message'] as String?,
    );
  }

  static Map<String, double> _rect(Rect r) =>
      {'x': r.left, 'y': r.top, 'width': r.width, 'height': r.height};

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
