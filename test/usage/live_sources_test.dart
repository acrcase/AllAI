// Canlı kaynaklar: gerçek ağ, anahtarlık, gh ve Antigravity sunucusu.
// Çalıştırma: ALLAI_LIVE=1 flutter test test/usage/live_sources_test.dart
// Widget binding'i başlatılmaz ki gerçek HttpClient çalışsın. Belirteç basılmaz.
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:allai/l10n/l10n.dart';
import 'package:allai/usage/sources/antigravity_source.dart';
import 'package:allai/usage/sources/chatgpt_source.dart';
import 'package:allai/usage/sources/claude_source.dart';
import 'package:allai/usage/sources/copilot_source.dart';
import 'package:allai/usage/usage_models.dart';
import 'package:allai/usage/web_probe.dart';
import 'package:flutter_test/flutter_test.dart';

final _skip = Platform.environment['ALLAI_LIVE'] == '1' ? null : 'ALLAI_LIVE=1 ile çalıştır';

void _print(UsageReport r) {
  final b = StringBuffer('[${r.serviceId}] ${r.status.name} · plan=${r.plan} · kaynak=${r.source}');
  if (r.message != null) b.write('\n  mesaj: ${r.message}');
  for (final s in r.sections) {
    b.write('\n  -- ${s.title ?? '(başlıksız)'}');
    for (final m in s.meters) {
      final pct = m.unlimited ? 'sınırsız' : (m.remaining == null ? '—' : '%${(m.remaining! * 100).toStringAsFixed(1)} kaldı');
      b.write('\n     ${m.label}: $pct${m.estimated ? ' (tahmini)' : ''}'
          '${m.detail == null ? '' : ' · ${m.detail}'}'
          '${m.resetsAt == null ? '' : ' · sıfırlanma ${m.resetsAt!.toLocal()}'}');
    }
  }
  // ignore: avoid_print — canlı testin çıktısı rapora girer.
  print(b);
}

Future<int> _hubServers() async {
  final r = await Process.run('/usr/bin/pgrep', ['-f', 'language_server -standalone']);
  return r.stdout.toString().trim().split('\n').where((l) => l.isNotEmpty).length;
}

void main() {
  setUpAll(() => L10n.instance.debugSet('tr'));

  test('claude (Claude Code OAuth)', () async {
    final r = await ClaudeCodeSource().fetch();
    _print(r);
    expect(r.status, anyOf(UsageStatus.ok, UsageStatus.noData));
    if (r.status == UsageStatus.ok) {
      expect(r.sections.first.meters.first.label, '5 saatlik oturum');
      expect(r.plan, 'Max 20x');
    }
  }, skip: _skip);

  // NOT: Claude uygulaması/Chrome hesabının canlı okuması artık AllAI'nin KENDİ süreci üzerinden
  // (native `allai/keychain` kanalı) yapılır; `flutter test` o kanalı sağlamaz. Bu yüzden gerçek
  // doğrulama yalnız uygulamada panelden "bağla" ile yapılır (başsız canlı test yoktur).

  test('antigravity (yerel sunucu) ve süreç kapanıyor', () async {
    final before = await _hubServers();
    final dir = await Directory.systemTemp.createTemp('ag_ls');
    addTearDown(() => dir.delete(recursive: true));
    final sw = Stopwatch()..start();
    final r = await AntigravitySource(workDir: () async => dir).fetch();
    // ignore: avoid_print — süre rapora girer.
    print('antigravity süresi: ${sw.elapsedMilliseconds} ms');
    _print(r);
    expect(r.status, UsageStatus.ok);
    expect([for (final s in r.sections) s.title], contains('Claude modelleri'));
    expect(await _hubServers(), before, reason: 'başlatılan sunucu kapanmalı');
    expect(dir.listSync(), isEmpty, reason: 'sunucu günlüğü tutulmaz');
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 40)));

  test('copilot (gh + copilot_internal/user)', () async {
    final r = await CopilotSource().fetch();
    _print(r);
    expect(r.status, UsageStatus.ok);
    expect(r.sections.first.meters.single.remaining, isNotNull);
  }, skip: _skip);

  test('chatgpt: web sondası olmadan Codex kaydına düşer', () async {
    final r = await ChatGptSource(probe: (_, _) => throw const WebProbeException('testte web görünümü yok'))
        .fetch();
    _print(r);
    expect(r.sections.first.title, 'Codex (son bilinen)');
  }, skip: _skip);
}
