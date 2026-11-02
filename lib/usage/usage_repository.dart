import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import 'sources/antigravity_source.dart';
import 'sources/chatgpt_source.dart';
import 'sources/claude_source.dart';
import 'sources/copilot_source.dart';
import 'sources/counted_sources.dart';
import 'sources/m365_copilot_source.dart';
import 'usage_models.dart';

/// Bir uygulamanın limitlerini getiren kaynak.
abstract class UsageSource {
  /// `AiService.usageKey` ile aynı.
  String get serviceId;

  /// Panelde görünen başlık ("Antigravity", "Claude (web)").
  String get title;

  /// Gizli web görünümü kullanır: bu kaynaklar bellek için sırayla çalışır.
  bool get usesWebView => false;

  /// Toplu yenilemede bu kaynak, adı verilen kaynak bittikten sonra çalışır.
  String? get runAfter => null;

  /// Kartı olmayan, [UsageRepository.order] dışı olsa da hep gösterilen ve yenilenen kaynak
  /// (ör. Claude Code satırı — kullanıcının eklediği/kaldırdığı bir kart değil).
  bool get alwaysActive => false;

  /// Bu kaynağın verisi bu süreden eskiyse arka planda yenilenir. Gizli web görünümü ya da
  /// süreç başlatan kaynaklar pahalıdır: seyrek yenilenir.
  Duration get maxAge => usesWebView ? const Duration(minutes: 15) : const Duration(minutes: 5);

  /// Okuma kullanıcı onayı (anahtarlık izni) gerektiriyor mu.
  bool get requiresConsent => false;

  /// Onay verildiyse true. Kalıcı kaynaklarda açılışta [load] içinde yüklenir.
  bool consentGranted = false;

  /// Onayı değiştirir (ve kalıcıysa diske yazar). Alt sınıf kalıcılık için ezer.
  Future<void> setConsent(bool granted) async => consentGranted = granted;

  /// Asla fırlatmaz: hatayı `UsageStatus.error` raporuna çevirir.
  Future<UsageReport> fetch();
}

/// Bütün kaynakları yönetir, son raporları önbellekte tutar.
///
/// SÖZLEŞME (arayüz bunlara dayanır):
/// - [reports]: serviceId -> son rapor (önbellekten yüklenmiş olabilir)
/// - [order]: panelde gösterilecek serviceId sırası
/// - [refreshing]: o an yenilenen serviceId'ler
/// - [refreshAll] / [refresh]: yeniden çeker, [notifyListeners] çağırır
/// - [lastRefresh]: son tam yenileme zamanı
/// - [setOrder]: ana ekrandaki kart sırası değişince çağrılır; panel bu sırayı izler
class UsageRepository extends ChangeNotifier {
  UsageRepository._()
      : _cacheDir = getApplicationSupportDirectory,
        timeout = const Duration(seconds: 25),
        period = const Duration(minutes: 1) {
    // Varsayılan sıra ana ekranınkiyle aynı; Gemini, planı için Antigravity'den sonra gelir.
    _sources = [
      ChatGptSource(),
      AntigravitySource(),
      CopilotSource(),
      M365CopilotSource(),
      GeminiSource(planHint: () => reports['antigravity']?.plan),
      DeepSeekSource(),
      ClaudeAppSource(),
      ClaudeCodeSource(),
      ClaudeWebSource(),
    ];
  }

  @visibleForTesting
  UsageRepository.withSources(
    List<UsageSource> sources, {
    required this._cacheDir,
    this.timeout = const Duration(seconds: 25),
    this.period = const Duration(minutes: 1),
  }) {
    _sources = sources;
  }

  static final instance = UsageRepository._();

  late final List<UsageSource> _sources;
  final Future<Directory> Function() _cacheDir;

  /// Kaynak başına zaman aşımı.
  final Duration timeout;

  /// Bayat kaynak denetiminin aralığı: her turda yalnız süresi dolan kaynak çekilir.
  final Duration period;

  final Map<String, UsageReport> reports = {};
  final List<String> order = [];
  final Set<String> refreshing = {};
  DateTime? lastRefresh;

  Future<void>? _init;
  Future<void>? _all;
  bool _orderSet = false;
  Timer? _timer;
  Timer? _saveTimer;
  AppLifecycleListener? _lifecycle;
  bool _active = true;
  final Map<String, Future<void>> _running = {};
  Future<void> _webTail = Future.value();
  Future<void> _saveTail = Future.value();

  /// Önbelleği yükler, kaynakları kaydeder, periyodik yenilemeyi başlatır.
  Future<void> init() => _init ??= _start();

  Future<void> _start() async {
    if (!_orderSet) order.addAll([for (final s in _sources) s.serviceId]);
    await _loadCache();
    final now = DateTime.now();
    for (final s in _sources) {
      reports.putIfAbsent(
        s.serviceId,
        () => UsageReport(serviceId: s.serviceId, title: s.title, status: UsageStatus.loading, fetchedAt: now),
      );
    }
    notifyListeners();
    // Kaynakların ürettiği mesajlar çevrilmiş metin olarak önbelleğe yazılır: dil değişince yeniden üret.
    L10n.instance.addListener(_onLanguageChanged);
    _timer = Timer.periodic(period, (_) => refreshStale());
    // Açılış animasyonu bitsin; önbellek tazeyse hiç çekilmez.
    Timer(const Duration(seconds: 4), refreshStale);
  }

  void _onLanguageChanged() => unawaited(refreshAll());

  /// Pencere arka plandayken yoklama durur; öne gelince bayat olanlar tazelenir.
  void watchLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onStateChange: (state) {
        final active = state == AppLifecycleState.resumed;
        if (active && !_active) Timer(const Duration(seconds: 1), refreshStale);
        _active = active;
      },
    );
  }

  /// Verisi bayatlamış kaynakları yeniden çeker. [maxAge] verilirse her kaynağın kendi süresi yerine
  /// o geçerli olur (panel açılışında kısa). Giriş/onay bekleyen ve bu cihazda olmayan kaynaklar
  /// yoklanmaz: durum değişince (giriş, bağlama) ayrıca tazelenir.
  Future<void> refreshStale({Duration? maxAge}) async {
    if (!_active || _init == null) return;
    final now = DateTime.now();
    final started = <String, Future<void>>{};
    for (final s in _sources) {
      if (!order.contains(s.serviceId) && !s.alwaysActive) continue;
      final r = reports[s.serviceId];
      if (r != null) {
        if (r.status case UsageStatus.needsLogin || UsageStatus.needsConsent || UsageStatus.unavailable) continue;
        if (r.status != UsageStatus.loading && now.difference(r.fetchedAt) < (maxAge ?? s.maxAge)) continue;
      }
      final after = started[s.runAfter];
      started[s.serviceId] = after == null ? refresh(s.serviceId) : after.then((_) => refresh(s.serviceId));
    }
    if (started.isEmpty) return;
    await Future.wait(started.values);
    await _flushSave();
    lastRefresh = DateTime.now();
    notifyListeners();
  }

  Future<void> refreshAll() => _all ??= _refreshAll().whenComplete(() => _all = null);

  Future<void> _refreshAll() async {
    final started = <String, Future<void>>{};
    for (final s in _sources) {
      if (!order.contains(s.serviceId) && !s.alwaysActive) continue;
      final after = started[s.runAfter];
      started[s.serviceId] = after == null ? refresh(s.serviceId) : after.then((_) => refresh(s.serviceId));
    }
    await Future.wait(started.values);
    await _flushSave();
    lastRefresh = DateTime.now();
    notifyListeners();
  }

  Future<void> refresh(String serviceId) {
    final running = _running[serviceId];
    if (running != null) return running;
    final source = _sources.where((s) => s.serviceId == serviceId).firstOrNull;
    if (source == null) return Future.value();
    refreshing.add(serviceId);
    notifyListeners();
    return _running[serviceId] = _run(source).whenComplete(() {
      _running.remove(serviceId);
      refreshing.remove(serviceId);
      notifyListeners();
    });
  }

  /// Onay bayrağını ayarlar (kalıcı) ve yeniden çeker. [grant] true = "bağla" düğmesi,
  /// false = "bağlantıyı kes". Onaydan önce kaynak anahtarlığa dokunmaz (izin penceresi açılmaz).
  /// Bağlantıyı keserken SÜREN okuma beklenir (çerezi henüz göndermemişse iptal olur), sonra yenilenir.
  /// Future döner (UI ateşle-unut çağırır; test bekleyebilir).
  Future<void> setConsent(String serviceId, bool grant) async {
    final source = _sources.where((s) => s.serviceId == serviceId).firstOrNull;
    if (source == null || !source.requiresConsent) return;
    await source.setConsent(grant); // bayrağı çevirir; false ise anahtarı sıfırlar (forgetKey)
    final running = _running[serviceId];
    if (running != null) await running; // süren işi bekle
    await refresh(serviceId);
  }

  Future<void> grantConsent(String serviceId) => setConsent(serviceId, true);

  void setOrder(List<String> usageKeys) {
    final known = {for (final s in _sources) s.serviceId};
    final next = <String>[];
    for (final k in usageKeys) {
      if (known.contains(k) && !next.contains(k)) next.add(k);
    }
    _orderSet = true;
    if (listEquals(next, order)) return;
    final added = [for (final k in next) if (!order.contains(k)) k];
    order
      ..clear()
      ..addAll(next);
    notifyListeners();
    // Yeni görünen kartın verisi hiç çekilmediyse hemen çek.
    if (_init == null) return;
    for (final k in added) {
      final r = reports[k];
      if (r == null || r.status == UsageStatus.loading) unawaited(refresh(k));
    }
  }

  Future<void> _run(UsageSource s) async {
    final fresh = s.usesWebView ? await _serialWeb(() => _fetch(s)) : await _fetch(s);
    reports[s.serviceId] = mergeReports(reports[s.serviceId], fresh);
    // Toplu yenilemede her kaynak için ayrı yazma yerine tek yazma.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () => unawaited(_save()));
  }

  Future<UsageReport> _fetch(UsageSource s) async {
    UsageReport failed(String message) => UsageReport(
        serviceId: s.serviceId,
        title: s.title,
        status: UsageStatus.error,
        message: message,
        fetchedAt: DateTime.now());
    try {
      return await s.fetch().timeout(timeout);
    } on TimeoutException {
      return failed(t('usage.err.timeoutSec', {'n': timeout.inSeconds}));
    } catch (_) {
      return failed(t('usage.err.unexpected'));
    }
  }

  // Gizli web görünümleri aynı anda tek tane açılır; zaman aşımı sıra gelince başlar.
  Future<T> _serialWeb<T>(Future<T> Function() task) {
    final result = _webTail.then((_) => task());
    _webTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<File> _cacheFile() async => File('${(await _cacheDir()).path}/usage_cache.json');

  Future<void> _loadCache() async {
    try {
      final j = jsonDecode(await (await _cacheFile()).readAsString());
      final known = {for (final s in _sources) s.serviceId};
      for (final r in (j as Map)['reports'] as List) {
        final report = UsageReport.fromJson((r as Map).cast<String, Object?>());
        if (known.contains(report.serviceId)) reports[report.serviceId] = report;
      }
    } catch (_) {}
  }

  Future<void> _flushSave() {
    if (_saveTimer?.isActive != true) return _saveTail;
    _saveTimer!.cancel();
    return _save();
  }

  Future<void> _save() {
    final next = _saveTail.then((_) async {
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'version': 1,
        'reports': [
          for (final r in reports.values)
            if (r.status != UsageStatus.loading) r.toJson(),
        ],
      }));
      await tmp.rename(file.path);
    });
    _saveTail = next.then<void>((_) {}, onError: (_) {});
    return _saveTail;
  }

  @override
  void dispose() {
    L10n.instance.removeListener(_onLanguageChanged);
    _timer?.cancel();
    _saveTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}

/// Yeni rapor veri getirmediyse önceki iyi veriyi korur, durumu ve mesajı günceller.
/// [UsageStatus.needsConsent] kesin bir durumdur (ör. bağlantı kesildi): eski limitler korunmaz.
@visibleForTesting
UsageReport mergeReports(UsageReport? previous, UsageReport fresh) {
  if (fresh.status == UsageStatus.ok ||
      fresh.status == UsageStatus.unavailable ||
      fresh.status == UsageStatus.needsConsent ||
      fresh.sections.isNotEmpty ||
      previous == null ||
      previous.sections.isEmpty) {
    return fresh;
  }
  return previous.copyWith(status: fresh.status, message: fresh.message);
}
