import 'dart:convert';
import 'dart:io';

import 'package:allai/l10n/l10n.dart';
import 'package:allai/usage/cookie_store.dart';
import 'package:allai/usage/sources/antigravity_source.dart';
import 'package:allai/usage/sources/chatgpt_source.dart';
import 'package:allai/usage/sources/claude_source.dart';
import 'package:allai/usage/sources/copilot_source.dart';
import 'package:allai/usage/usage_models.dart';
import 'package:flutter_test/flutter_test.dart';

// Makinede alınan gerçek yanıtlardan kısaltılmış örnekler (24 Eki 2026).
const _claudeUsage = '''
{"five_hour":{"utilization":31.0,"resets_at":"2026-10-24T13:20:00.097931+00:00"},
 "seven_day":{"utilization":27.0,"resets_at":"2026-10-30T18:00:00.097949+00:00"},
 "seven_day_opus":null,"seven_day_sonnet":null,
 "limits":[
  {"kind":"session","group":"session","percent":31,"resets_at":"2026-10-24T13:20:00.097931+00:00","scope":null},
  {"kind":"weekly_all","group":"weekly","percent":27,"resets_at":"2026-10-30T18:00:00.097949+00:00","scope":null},
  {"kind":"weekly_scoped","group":"weekly","percent":2,"resets_at":"2026-10-30T18:00:00.098101+00:00",
   "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],
 "seven_day_breakdown":{"rows":[{"key":"claude_code","display_name":"Claude Code","percent":100},
   {"key":"chat","display_name":"Chats","percent":0}]},
 "weekly_scoped_shares":[{"limit_index":2,"used_percent_of_weekly":1,"allowance_percent_of_weekly":50}]}
''';

const _copilotUser = '''
{"access_type_sku":"free_educational_quota","copilot_plan":"individual",
 "quota_reset_date":"2026-11-01","quota_reset_date_utc":"2026-11-01T00:00:00.000Z","token_based_billing":true,
 "quota_snapshots":{
  "chat":{"unlimited":true,"percent_remaining":100.0,"remaining":0,"entitlement":0},
  "completions":{"unlimited":true,"percent_remaining":100.0,"remaining":0,"entitlement":0},
  "premium_interactions":{"entitlement":200,"remaining":200,"quota_remaining":200.0,
    "percent_remaining":100.0,"unlimited":false,"overage_permitted":false}}}
''';

const _codexLine =
    '{"timestamp":"2026-10-14T06:40:42.702Z","type":"event_msg","payload":{"type":"token_count",'
    '"rate_limits":{"limit_id":"codex","primary":{"used_percent":61.0,"window_minutes":43200,'
    '"resets_at":4102444800},"secondary":null,"credits":{"has_credits":false},"plan_type":"free"}}}';

void main() {
  setUpAll(() => L10n.instance.debugSet('tr'));

  group('Claude', () {
    test('limits dizisi etiketlere ve kalan orana çevrilir', () {
      final sections = parseClaudeUsage(jsonDecode(_claudeUsage));
      final meters = sections.single.meters;
      expect([for (final m in meters) m.label],
          ['5 saatlik oturum', 'Haftalık · tüm modeller', 'Haftalık · Fable']);
      expect(meters[0].remaining, closeTo(0.69, 1e-9));
      expect(meters[0].resetsAt, DateTime.utc(2026, 10, 24, 13, 20, 0, 97, 931));
      expect(meters[1].detail, 'Bu haftaki kullanım: Claude Code %100');
      expect(meters[2].detail, 'Haftalık kotanın en çok %50\'i');
      expect(meters[2].remaining, closeTo(0.98, 1e-9));
    });

    test('limits yoksa eski alanlara düşer', () {
      final j = jsonDecode(_claudeUsage) as Map<String, dynamic>..remove('limits');
      final labels = [for (final m in parseClaudeUsage(j).single.meters) m.label];
      expect(labels, ['5 saatlik oturum', 'Haftalık · tüm modeller']);
    });

    test('tanınmayan yanıt boş liste', () {
      expect(parseClaudeUsage({'error': 'x'}), isEmpty);
      expect(parseClaudeUsage(null), isEmpty);
    });

    test('plan adı', () {
      expect(claudePlan(tier: 'default_claude_max_20x', subscription: 'max'), 'Max 20x');
      expect(claudePlan(tier: 'default_claude_ai', subscription: 'pro'), 'Pro');
      expect(claudePlan(), isNull);
    });

    test('web sonucu: 403 giriş ister, 200 ayrıştırılır', () {
      final s = ClaudeWebSource(probe: (_, _) async => null);
      UsageReport parse(Object? r) =>
          parseClaudeWebResult(s, r, source: 'claude.ai oturumu', login: 'giriş yap');
      expect(parse({'status': 403}).status, UsageStatus.needsLogin);
      final ok = parse({
        'status': 200,
        'usage': jsonDecode(_claudeUsage),
        'tier': 'default_claude_max_5x',
        'capabilities': ['chat', 'claude_max'],
      });
      expect(ok.status, UsageStatus.ok);
      expect(ok.plan, 'Max 5x');
      expect(ok.sections.single.meters, hasLength(3));
    });

    test('capabilities ücretli plan içermiyorsa plan "Ücretsiz" (asla Max değil)', () {
      final s = ClaudeWebSource(probe: (_, _) async => null);
      final r = parseClaudeWebResult(s, {
        'status': 200,
        'usage': jsonDecode(_claudeUsage),
        'tier': 'default_claude_ai',
        'capabilities': ['chat'],
      }, source: 'x', login: 'y');
      expect(r.plan, 'Ücretsiz');
    });

    test('kaynaklar ayrı serviceId: Code -> claude-code, uygulama -> claude', () {
      final code = ClaudeCodeSource();
      expect(code.serviceId, 'claude-code', reason: 'Claude Code planı artık claude kartına gitmez');
      expect(code.title, 'Claude Code');
      expect(code.alwaysActive, isTrue, reason: 'kartı yok ama hep gösterilir/yenilenir');
      final app = ClaudeAppSource();
      expect(app.serviceId, 'claude', reason: 'uygulama kartı bağlı hesabı gösterir');
      expect(app.requiresConsent, isTrue);
      expect(code.serviceId, isNot(app.serviceId));
    });

    test('ClaudeAppSource onaysızken anahtarlığa/çereze dokunmaz, needsConsent (asla Max)', () async {
      final store = ChromiumCookieStore(
        cookiesDbPath: '/var/empty/does-not-exist/Cookies',
        safeStorageService: 'x',
        runProcess: (_, _) async => fail('onaydan önce komut çalışmamalı'),
        passwordReader: (_) async => fail('onaydan önce anahtarlık okunmamalı'),
      );
      final r = await ClaudeAppSource(store: store).fetch();
      if (Platform.isMacOS) {
        expect(r.status, UsageStatus.needsConsent);
        expect(r.plan, isNull, reason: 'onay yokken plan bilinmez; asla Max demez');
        expect(r.actionLabel, 'Claude hesabını bağla');
      } else {
        expect(r.status, UsageStatus.unavailable);
      }
    });

    test('chromeProfileName: yol kaçışı engellenir, yalnız Default/Profile N', () {
      expect(chromeProfileName('Default'), 'Default');
      expect(chromeProfileName('Profile 2'), 'Profile 2');
      expect(chromeProfileName('../../Library'), 'Default');
      expect(chromeProfileName('Default?immutable=0'), 'Default');
      expect(chromeProfileName('Profile 1#x'), 'Default');
      expect(chromeProfileName('/etc/passwd'), 'Default');
      expect(chromeProfileName(null), 'Default');
      expect(chromeProfileName(42), 'Default');
    });

    test('bağlantı kesilince (consented=false) çerez GÖNDERİLMEZ', () async {
      final db = await File('${Directory.systemTemp.createTempSync('rc').path}/Cookies').create();
      addTearDown(() => db.parent.delete(recursive: true));
      const enc =
          '76313008f7bbfc523d35b7871b09005537fcf73bcc6e06257932166f709e979c'
          '1d4aa7b06694d29f091e723191c9c4d8c642bec8889be89a79ca2904411387c44bba20';
      final store = ChromiumCookieStore(
        cookiesDbPath: db.path,
        safeStorageService: 'x',
        passwordReader: (_) async => 'test-pass-123',
        runProcess: (exe, args) async {
          final sql = args.last;
          if (sql.contains('FROM meta')) return '24';
          if (sql.contains('FROM cookies')) return '.claude.ai\x1esessionKey\x1e\x1e$enc\x1f';
          return null;
        },
      );
      var reqCalls = 0;
      Future<(int, Object?)> req(String m, Uri u,
              {Map<String, String> headers = const {}, Object? body, Duration timeout = Duration.zero}) async {
        reqCalls++;
        return (200, const []);
      }

      final r = await claudeUsageFromCookies(ClaudeAppSource(), store,
          requester: req, source: 'x', login: 'y', consented: () => false);
      expect(reqCalls, 0, reason: 'onay geri alınmışsa claude.ai\'ye çerez gitmez');
      expect(r.status, UsageStatus.noData);
      expect(r.plan, isNull);
    });

    test('/usage yanıtı yalnız gereken alanlara kırpılır', () {
      final trimmed = trimClaudeUsage({
        'five_hour': {'utilization': 10},
        'limits': [{'kind': 'session', 'percent': 5}],
        'seven_day_breakdown': {'rows': []},
        'account_email': 'gizli@example.com', // taşınmamalı
        'raw_blob': List.filled(1000, 'x'),
      });
      expect((trimmed! as Map).keys, containsAll(['five_hour', 'limits', 'seven_day_breakdown']));
      expect((trimmed as Map).containsKey('account_email'), isFalse);
      expect(trimmed.containsKey('raw_blob'), isFalse);
    });

    test('GÜVENLİK: parola ve çerez değeri mesaja/önbellek JSON\'una/alt sürece sızmaz', () async {
      if (!Platform.isMacOS) return;
      final db = await File('${Directory.systemTemp.createTempSync('sec').path}/Cookies').create();
      addTearDown(() => db.parent.delete(recursive: true));
      const pw = 'test-pass-123'; // sahte "sır" (bu anahtar _encV24'ü çözer)
      const enc =
          '76313008f7bbfc523d35b7871b09005537fcf73bcc6e06257932166f709e979c'
          '1d4aa7b06694d29f091e723191c9c4d8c642bec8889be89a79ca2904411387c44bba20';
      final sqlArgs = <String>[];
      final store = ChromiumCookieStore(
        cookiesDbPath: db.path,
        safeStorageService: 'x',
        passwordReader: (_) async => pw,
        runProcess: (exe, args) async {
          sqlArgs.addAll(args);
          final sql = args.last;
          if (sql.contains('FROM meta')) return '24';
          if (sql.contains('FROM cookies')) return '.claude.ai\x1esessionKey\x1e\x1e$enc\x1f';
          return null;
        },
      );
      // Sahte istek atıcı: Cookie başlığını yakalar, kanonik yanıt döner (ağa çıkmaz).
      final sentHeaders = <String, String>{};
      Future<(int, Object?)> fakeReq(String m, Uri url,
          {Map<String, String> headers = const {}, Object? body, Duration timeout = Duration.zero}) async {
        sentHeaders.addAll(headers);
        if (url.path.endsWith('/organizations')) {
          return (200, [
            {'uuid': 'u1', 'capabilities': ['chat'], 'rate_limit_tier': 'default_claude_ai'}
          ]);
        }
        return (200, {'five_hour': {'utilization': 20, 'resets_at': '2026-10-24T13:00:00Z'}});
      }

      final source = ClaudeAppSource(store: store, requester: fakeReq)..consentGranted = true;
      final r = await source.fetch();

      expect(r.status, UsageStatus.ok);
      expect(r.plan, 'Ücretsiz');
      expect(r.connected, isTrue, reason: 'kartta bağlantıyı kes görünsün');
      // Değer gönderildi (amaç bu) ama yalnız Cookie başlığında.
      expect(sentHeaders['Cookie'], contains('sessionKey=fake-session-abc'));
      // KRİTİK: sır ne mesajda, ne önbellek JSON'unda, ne de sqlite argümanlarında.
      final cacheJson = jsonEncode(r.toJson());
      for (final secret in [pw, 'fake-session-abc']) {
        expect(r.message ?? '', isNot(contains(secret)));
        expect(cacheJson, isNot(contains(secret)));
        expect(sqlArgs.join('\u0000'), isNot(contains(secret)));
      }
    });
  });

  group('Antigravity', () {
    test('aileye göre bölümler, ortak kotalı modlar birleşir', () {
      final sections = antigravitySections([
        {'label': 'Gemini 4 Argon (Low)', 'quotaInfo': {'remainingFraction': 0.99397266, 'resetTime': '2026-10-30T20:12:50Z'}},
        {'label': 'Gemini 4 Argon (High)', 'quotaInfo': {'remainingFraction': 0.99397266, 'resetTime': '2026-10-30T20:12:50Z'}},
        {'label': 'Claude Opus 5.5 (High)', 'quotaInfo': {'remainingFraction': 1, 'resetTime': '2026-10-24T15:18:20Z'}},
        {'label': 'Claude Opus 5.5 (Low)', 'quotaInfo': {'remainingFraction': 1, 'resetTime': '2026-10-24T15:18:20Z'}},
        {'label': 'Claude Sonnet 5.5 (Low)', 'quotaInfo': {'resetTime': '2026-10-24T15:18:20Z'}},
        {'label': 'Claude Sonnet 5.5 (High)', 'quotaInfo': {'remainingFraction': 0.5, 'resetTime': '2026-10-24T15:18:20Z'}},
        {'label': 'GPT-OSS 120B (Medium)', 'quotaInfo': {'remainingFraction': 1, 'resetTime': '2026-10-24T15:18:20Z'}},
        {'label': 'Kotasız model'},
      ]);
      expect([for (final s in sections) s.title], ['Gemini modelleri', 'Claude modelleri', 'GPT-OSS · Diğer']);
      final gemini = sections[0].meters.single;
      expect(gemini.label, 'Gemini 4 Argon');
      expect(gemini.detail, 'Low · High ortak kota');
      expect(gemini.remaining, closeTo(0.99397266, 1e-9));
      final claude = sections[1].meters;
      expect([for (final m in claude) m.label],
          ['Claude Opus 5.5', 'Claude Sonnet 5.5 (High)', 'Claude Sonnet 5.5 (Low)']);
      // remainingFraction yok ama resetTime var: kota bitmiş.
      expect(claude[2].remaining, 0);
      expect(sections[2].meters.single.label, 'GPT-OSS 120B (Medium)');
    });

    test('geçersiz CSRF / oturum hatası', () {
      final s = AntigravitySource(workDir: () async => Directory.systemTemp);
      expect(s.parseUserStatus(401, {'code': 'unauthenticated', 'message': 'unauthenticated: invalid CSRF token'}).status,
          UsageStatus.needsLogin);
      expect(s.parseUserStatus(500, null).status, UsageStatus.error);
      final ok = s.parseUserStatus(200, {
        'userStatus': {
          'userTier': {'name': 'Google AI Pro'},
          'cascadeModelConfigData': {
            'clientModelConfigs': [
              {'label': 'Gemini 3.8 Flash (Low)', 'quotaInfo': {'remainingFraction': 1, 'resetTime': '2026-10-24T15:18:20Z'}},
            ],
          },
        },
      });
      expect(ok.status, UsageStatus.ok);
      expect(ok.plan, 'Google AI Pro');
    });
  });

  group('Copilot', () {
    test('kredi faturalaması: AI kredisi ve model başına tahmin', () {
      final r = CopilotSource().parseCopilotUser(jsonDecode(_copilotUser));
      expect(r.status, UsageStatus.ok);
      expect(r.plan, 'Copilot Student');
      final credit = r.sections[0].meters.single;
      expect(r.sections[0].title, 'Aylık AI kredisi');
      expect(credit.remaining, 1.0);
      expect(credit.detail, '200 / 200 kredi (1 kredi = 0,01 \$)');
      expect(credit.resetsAt, DateTime.utc(2026, 11, 1));
      final perModel = {for (final m in r.sections[1].meters) m.label: m};
      // 8K × 2 $ + 1K × 12 $ = 0,028 $ = 2,8 kredi -> 200 / 2,8 = 71.
      expect(perModel['GPT-5.6 Terra']!.detail, '~71 istek · 2.8 kredi/istek');
      expect(perModel['GPT-5.6 Terra']!.estimated, isTrue);
      // Kredi faturalamasında "sınırsız sohbet" gösterilmez; kod tamamlama sınırsız.
      final included = r.sections[2].meters;
      expect([for (final m in included) m.label], ['Kod tamamlama']);
      expect(included.single.unlimited, isTrue);
      expect(r.message, contains('otomatik seçilir'));
    });

    test('eski istek faturalaması: çarpanla tahmin', () {
      final j = jsonDecode(_copilotUser) as Map<String, dynamic>;
      j['token_based_billing'] = false;
      j['access_type_sku'] = 'monthly_subscriber';
      (j['quota_snapshots'] as Map)['premium_interactions'] = {
        'entitlement': 300, 'remaining': 184, 'percent_remaining': 61.33, 'unlimited': false};
      final r = CopilotSource().parseCopilotUser(j);
      expect(r.plan, 'Copilot Pro');
      expect(r.sections[0].meters.single.detail, '184 / 300 istek');
      final perModel = {for (final m in r.sections[1].meters) m.label: m.detail};
      expect(perModel['GPT-5.1'], '~61 istek (×3)');
      expect(perModel['Claude Opus 4.8'], '~6 istek (×27)');
      expect([for (final m in r.sections[2].meters) m.label], ['Kod tamamlama', 'Sohbet']);
    });
  });

  group('ChatGPT', () {
    test('wham/usage yanıtı Codex pencerelerine çevrilir', () {
      final s = ChatGptSource(probe: (_, _) async => null, codexSessions: Directory('/yok'));
      final r = s.parseWebResult({
        'status': 200,
        'usage': {
          'plan_type': 'plus',
          'rate_limit': {
            'allowed': true,
            'limit_reached': false,
            'primary_window': {'used_percent': 12, 'limit_window_seconds': 18000, 'reset_after_seconds': 600, 'reset_at': 4102444800},
            'secondary_window': {'used_percent': 40, 'limit_window_seconds': 604800, 'reset_after_seconds': 6000},
          },
          'additional_rate_limits': [
            {'limit_name': 'GPT-5.6 Sol', 'rate_limit': {'primary_window': {'used_percent': 50, 'limit_window_seconds': 18000}}},
          ],
          'credits': {'has_credits': false, 'unlimited': false, 'balance': null},
        },
      });
      expect(r.status, UsageStatus.ok);
      expect(r.plan, 'Plus');
      final meters = r.sections.first.meters;
      expect([for (final m in meters) m.label],
          ['5 saatlik pencere', 'Haftalık pencere', 'GPT-5.6 Sol · 5 saatlik pencere']);
      expect(meters[0].remaining, closeTo(0.88, 1e-9));
      expect(meters[0].resetsAt, DateTime.utc(2100));
      expect(r.sections.last.title, 'ChatGPT sohbet');
      expect(r.sections.last.meters.single.remaining, isNull);
    });

    test('oturum yoksa giriş ister', () {
      final s = ChatGptSource(probe: (_, _) async => null, codexSessions: Directory('/yok'));
      expect(s.parseWebResult({'status': 401}).status, UsageStatus.needsLogin);
    });

    test('Codex kaydı: son bilinen limit, tahmini', () {
      final parsed = parseCodexRateLimits(
        (jsonDecode(_codexLine) as Map)['payload']['rate_limits'],
        at: DateTime.utc(2026, 10, 14, 6, 40),
      )!;
      expect(parsed.plan, 'Free');
      final m = parsed.meters.single;
      expect(m.label, '30 günlük pencere');
      expect(m.remaining, closeTo(0.39, 1e-9));
      expect(m.estimated, isTrue);
      expect(m.detail, startsWith('Son veri: 14 Eki 2026'));
    });

    test('süresi geçmiş pencere yüzde göstermez', () {
      final parsed = parseCodexRateLimits(
          {'primary': {'used_percent': 61.0, 'window_minutes': 43200, 'resets_at': 1700000000}})!;
      expect(parsed.meters.single.remaining, isNull);
    });

    test('web girişi yoksa Codex kaydına düşer', () async {
      final root = await Directory.systemTemp.createTemp('codex');
      addTearDown(() => root.delete(recursive: true));
      final day = await Directory('${root.path}/2026/10/14').create(recursive: true);
      await File('${day.path}/rollout-2026-10-14T09-00-00-a.jsonl').writeAsString('$_codexLine\n{"x":1}\n');
      // En yeni dosyada limit yok: bir öncekine bakılmalı.
      await File('${day.path}/rollout-2026-10-14T09-40-00-b.jsonl').writeAsString('{"x":1}\n');

      final s = ChatGptSource(probe: (_, _) async => {'status': 401}, codexSessions: root);
      final r = await s.fetch();
      expect(r.status, UsageStatus.needsLogin);
      expect(r.message, 'ChatGPT kartını açıp giriş yap');
      expect(r.plan, 'Free');
      expect(r.sections.first.title, 'Codex (son bilinen)');
      expect(r.sections.first.meters.single.remaining, closeTo(0.39, 1e-9));
    });
  });
}
