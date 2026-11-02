import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:allai/l10n/l10n.dart';
import 'package:allai/usage/usage_models.dart';
import 'package:allai/usage/usage_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSource extends UsageSource {
  FakeSource(
    this.serviceId,
    this.respond, {
    this.usesWebView = false,
    this.runAfter,
    this.alwaysActive = false,
    this.requiresConsent = false,
  });

  @override
  final String serviceId;
  @override
  String get title => serviceId.toUpperCase();
  @override
  final bool usesWebView;
  @override
  final String? runAfter;
  @override
  final bool alwaysActive;
  @override
  final bool requiresConsent;

  Future<UsageReport> Function() respond;
  int calls = 0;

  @override
  Future<UsageReport> fetch() {
    calls++;
    return respond();
  }
}

UsageReport rep(String id, UsageStatus status, {String? message, double? remaining}) => UsageReport(
      serviceId: id,
      title: id,
      status: status,
      message: message,
      fetchedAt: DateTime.now(),
      sections: remaining == null
          ? const []
          : [UsageSection(meters: [UsageMeter(label: 'm', remaining: remaining)])],
    );

void main() {
  setUpAll(() => L10n.instance.debugSet('tr'));

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('usage_repo'));
  tearDown(() => dir.delete(recursive: true));

  UsageRepository repo(List<UsageSource> sources, {Duration timeout = const Duration(seconds: 5)}) {
    final r = UsageRepository.withSources(sources,
        cacheDir: () async => dir, timeout: timeout, period: const Duration(hours: 1));
    addTearDown(r.dispose);
    return r;
  }

  test('açılışta önbellek anında görünür, yenileme sonra gelir', () async {
    File('${dir.path}/usage_cache.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'reports': [rep('a', UsageStatus.ok, remaining: 0.3).toJson(), rep('zzz', UsageStatus.ok).toJson()],
    }));
    final gate = Completer<UsageReport>();
    final r = repo([FakeSource('a', () => gate.future), FakeSource('b', () => gate.future)]);
    await r.init();
    expect(r.reports['a']!.lowestRemaining, 0.3);
    expect(r.reports['b']!.status, UsageStatus.loading);
    expect(r.reports.containsKey('zzz'), isFalse, reason: 'bilinmeyen kaynak önbellekten alınmaz');
    expect(r.refreshing, isEmpty, reason: 'açılışta tazeler hemen çekilmez');
    gate.complete(rep('a', UsageStatus.ok, remaining: 0.8));
    await r.refreshStale();
    expect(r.reports['a']!.lowestRemaining, 0.3, reason: 'taze önbellek yeniden çekilmez');
    expect(r.reports['b']!.status, UsageStatus.ok);
    await r.refreshAll();
    expect(r.refreshing, isEmpty);
    expect(r.lastRefresh, isNotNull);
    expect(r.reports['a']!.lowestRemaining, 0.8);
    final cached = jsonDecode(File('${dir.path}/usage_cache.json').readAsStringSync()) as Map;
    expect((cached['reports'] as List), hasLength(2));
  });

  test('hata önceki iyi veriyi korur, durum ve mesaj güncellenir', () async {
    final a = FakeSource('a', () async => rep('a', UsageStatus.ok, remaining: 0.5));
    final r = repo([a]);
    await r.refresh('a');
    a.respond = () async => rep('a', UsageStatus.error, message: 'HTTP 500');
    await r.refresh('a');
    expect(r.reports['a']!.status, UsageStatus.error);
    expect(r.reports['a']!.message, 'HTTP 500');
    expect(r.reports['a']!.lowestRemaining, 0.5);

    a.respond = () async => rep('a', UsageStatus.unavailable, message: 'kurulu değil');
    await r.refresh('a');
    expect(r.reports['a']!.sections, isEmpty, reason: 'kaldırılan kaynağın eski verisi gösterilmez');
  });

  test('zaman aşımı hata raporu olur, fırlatmaz', () async {
    final r = repo([FakeSource('a', () => Completer<UsageReport>().future)],
        timeout: const Duration(milliseconds: 50));
    await r.refresh('a');
    expect(r.reports['a']!.status, UsageStatus.error);
    expect(r.reports['a']!.message, startsWith('Zaman aşımı'));
  });

  test('fırlatan kaynak hata raporu olur', () async {
    final r = repo([FakeSource('a', () => Future.error(StateError('x')))]);
    await r.refresh('a');
    expect(r.reports['a']!.status, UsageStatus.error);
  });

  test('web kaynakları sırayla, diğerleri paralel; runAfter beklenir', () async {
    var webActive = 0, webMax = 0;
    final log = <String>[];
    Future<UsageReport> web(String id) async {
      webActive++;
      webMax = webActive > webMax ? webActive : webMax;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      webActive--;
      log.add(id);
      return rep(id, UsageStatus.ok);
    }

    Future<UsageReport> slow(String id) async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      log.add(id);
      return rep(id, UsageStatus.ok);
    }

    final r = repo([
      FakeSource('w1', () => web('w1'), usesWebView: true),
      FakeSource('base', () => slow('base')),
      FakeSource('dep', () async {
        log.add('dep');
        return rep('dep', UsageStatus.ok);
      }, runAfter: 'base'),
      FakeSource('w2', () => web('w2'), usesWebView: true),
    ]);
    r.setOrder(['w1', 'base', 'dep', 'w2']);
    await r.refreshAll();
    expect(webMax, 1);
    expect(log.indexOf('dep'), greaterThan(log.indexOf('base')));
    expect(log.toSet(), {'w1', 'w2', 'base', 'dep'});
  });

  test('setOrder bilinmeyeni atlar, tekrarı siler; yalnız sıradakiler yenilenir', () async {
    final a = FakeSource('a', () async => rep('a', UsageStatus.ok));
    final b = FakeSource('b', () async => rep('b', UsageStatus.ok));
    final r = repo([a, b]);
    var notified = 0;
    r.addListener(() => notified++);
    r.setOrder(['ozel-kart', 'b', 'b']);
    expect(r.order, ['b']);
    expect(notified, 1);
    r.setOrder(['b']);
    expect(notified, 1, reason: 'aynı sıra bildirim üretmez');
    await r.refreshAll();
    expect(a.calls, 0);
    expect(b.calls, 1);
  });

  test('mergeReports: needsConsent eski limitleri korumaz (bağlantı kesme kesin)', () {
    final prev = rep('claude', UsageStatus.ok, remaining: 0.5);
    final fresh = UsageReport(
      serviceId: 'claude',
      title: 'Claude',
      status: UsageStatus.needsConsent,
      fetchedAt: DateTime.now(),
      actionLabel: 'bağla',
    );
    final merged = mergeReports(prev, fresh);
    expect(merged.status, UsageStatus.needsConsent);
    expect(merged.sections, isEmpty, reason: 'onay geri alınınca eski limitler gösterilmez');
    expect(merged.actionLabel, 'bağla');
  });

  test('alwaysActive kaynak sıra dışı olsa da yenilenir ve gösterilir', () async {
    final a = FakeSource('a', () async => rep('a', UsageStatus.ok));
    final code = FakeSource('claude-code', () async => rep('claude-code', UsageStatus.ok),
        alwaysActive: true);
    final r = repo([a, code]);
    await r.init();
    // Yalnız kartı olan 'a' sıraya girer; claude-code sıra dışıdır.
    r.setOrder(['a']);
    expect(r.order, ['a']);
    await r.refreshAll();
    expect(code.calls, greaterThan(0), reason: 'kartı olmasa da alwaysActive yenilenmeli');
    expect(r.reports.containsKey('claude-code'), isTrue, reason: 'panelde satırı olmalı');
  });

  test('setConsent: bağla onay verir+yeniler, bağlantıyı kes geri alır', () async {
    final s = FakeSource('claude', () async => rep('claude', UsageStatus.ok), requiresConsent: true);
    final r = repo([s]);
    r.setOrder(['claude']);
    await r.refreshAll();
    final before = s.calls;
    // Onay gerektirmeyen bir serviceId'ye etkisizdir.
    await r.grantConsent('yok');
    await r.grantConsent('claude');
    expect(s.consentGranted, isTrue);
    expect(s.calls, greaterThan(before), reason: 'onay sonrası yeniden çekilir');
    // Bağlantıyı kes (onay geri alınır; süren iş beklenir, teardown temiz).
    await r.setConsent('claude', false);
    expect(s.consentGranted, isFalse);
  });

  test('aynı kaynak için eşzamanlı yenileme tek çağrıdır', () async {
    final gate = Completer<UsageReport>();
    final a = FakeSource('a', () => gate.future);
    final r = repo([a]);
    final f1 = r.refresh('a'), f2 = r.refresh('a');
    gate.complete(rep('a', UsageStatus.ok));
    await Future.wait([f1, f2]);
    expect(a.calls, 1);
    await r.refresh('bilinmeyen');
  });
}
