import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../cookie_store.dart';
import '../usage_models.dart';
import '../web_probe.dart';
import 'common.dart';
import '../../l10n/l10n.dart';

String get _expiredMessage => t('usage.claude.expired');

// Chrome masaüstü kimliği: Claude uygulaması/Chrome (Chromium) ve cf_clearance çerezi bu sınıf UA ile
// alındığından, doğrudan HTTP isteğinde buna yakın bir kimlik gönderilir.
// (Chrome 131, Ekim 2026 civarı; eşleşmezse Cloudflare isteği reddedebilir — o zaman dürüstçe "okunamadı".)
const _chromeUserAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

// Yalnız bu çerezler okunur/çözülür/gönderilir (dar sorgu).
const _claudeCookieHosts = ['claude.ai', '.claude.ai'];
const _claudeCookieNames = ['sessionKey', 'cf_clearance', '__cf_bm'];

/// `requestJson` ile aynı imza; testte sahte istek atıcı takılır (ağa çıkmadan doğrulama).
typedef JsonRequester = Future<(int, Object?)> Function(
  String method,
  Uri url, {
  Map<String, String> headers,
  Object? body,
  Duration timeout,
});

/// Kullanıcı onay bayrağı: shared_preferences'ta kalıcı, bellekte önbellekli. Sır DEĞİLDİR.
class ConsentFlag {
  ConsentFlag(this.prefsKey);

  final String prefsKey;
  bool? _cached;

  Future<bool> read() async {
    if (_cached != null) return _cached!;
    try {
      _cached = (await SharedPreferences.getInstance()).getBool(prefsKey) ?? false;
    } catch (_) {
      _cached = false;
    }
    return _cached!;
  }

  Future<void> write(bool v) async {
    _cached = v;
    try {
      await (await SharedPreferences.getInstance()).setBool(prefsKey, v);
    } catch (_) {}
  }
}

/// Claude Code hesabı: anahtarlıktaki OAuth belirteciyle `api/oauth/usage`.
///
/// Bu satırın planı/limiti Claude Code hesabına aittir; Claude masaüstü uygulaması kartına
/// ASLA atfedilmez (serviceId ayrı: 'claude-code'). Kartı yoktur; panelde ayrı satır olarak görünür.
///
/// Belirteç süresi dolmuşsa YENİLEMEZ; rapor boş gelir, depo önceki iyi veriyi korur.
class ClaudeCodeSource extends BaseSource {
  @override
  String get serviceId => 'claude-code';

  @override
  String get title => 'Claude Code';

  /// Kullanıcının eklediği/kaldırdığı bir kart değil; her zaman gösterilir ve yenilenir.
  @override
  bool get alwaysActive => true;

  static String get _source => t('usage.claude.codeSource');

  @override
  Future<UsageReport> load() async {
    if (!Platform.isMacOS) {
      return report(UsageStatus.unavailable, message: t('usage.claude.macKeychain'));
    }
    final raw = await runForOutput(
        '/usr/bin/security', ['find-generic-password', '-s', 'Claude Code-credentials', '-w']);
    if (raw == null) {
      return report(UsageStatus.needsLogin,
          message: t('usage.claude.noCodeSession'), source: _source);
    }
    Object? oauth;
    try {
      oauth = dig(jsonDecode(raw), ['claudeAiOauth']);
    } catch (_) {}
    final token = dig(oauth, ['accessToken']);
    final plan = claudePlan(
      tier: dig(oauth, ['rateLimitTier']) as String?,
      subscription: dig(oauth, ['subscriptionType']) as String?,
    );
    if (token is! String || token.isEmpty) {
      return report(UsageStatus.needsLogin,
          message: t('usage.claude.codeUnreadable'), plan: plan, source: _source);
    }
    final expiresAt = asDouble(dig(oauth, ['expiresAt']));
    if (expiresAt != null && expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      return report(UsageStatus.noData, message: _expiredMessage, plan: plan, source: _source);
    }

    final (code, body) = await requestJson(
      'GET',
      Uri.parse('https://api.anthropic.com/api/oauth/usage'),
      headers: {'Authorization': 'Bearer $token', 'anthropic-beta': 'oauth-2025-04-20'},
    );
    if (code == 401) {
      return report(UsageStatus.noData, message: _expiredMessage, plan: plan, source: _source);
    }
    if (code != 200) {
      return report(UsageStatus.error, message: t('usage.err.http', {'name': 'Anthropic', 'code': code}),
          plan: plan, source: _source);
    }
    final sections = parseClaudeUsage(body);
    if (sections.isEmpty) {
      return report(UsageStatus.noData, message: t('usage.err.unrecognized'), plan: plan, source: _source);
    }
    return report(UsageStatus.ok, plan: plan, sections: sections, source: _source);
  }
}

/// Claude masaüstü uygulamasının BAĞLI OLDUĞU claude.ai hesabı (uygulama kartı, serviceId 'claude').
///
/// Uygulamanın Chromium çerez deposundaki claude.ai oturumuyla `/api/organizations` + `.../usage`
/// okur; plan/limit o hesaba aittir. Anahtarlık, kullanıcı onayından sonra AllAI'nin KENDİ süreciyle
/// (native kanal) yalnız BİR kez okunur; türetilen anahtar bellekte kalır. Onaysızken anahtarlığa
/// dokunulmaz ve plan "bilinmiyor" kalır, ASLA Max demez.
class ClaudeAppSource extends BaseSource {
  ClaudeAppSource({
    ChromiumCookieStore? store,
    ConsentFlag? consent,
    this.requester = requestJson,
  })  : _store = store ??
            ChromiumCookieStore(
              cookiesDbPath:
                  '${Platform.environment['HOME']}/Library/Application Support/Claude/Cookies',
              safeStorageService: 'Claude Safe Storage',
            ),
        _consent = consent ?? ConsentFlag('usage.consent.claude');

  final ChromiumCookieStore _store;
  final ConsentFlag _consent;
  final JsonRequester requester;

  @override
  String get serviceId => 'claude';

  @override
  String get title => 'Claude';

  @override
  bool get requiresConsent => true;

  static String get _source => t('usage.claude.appSource');
  static String get _login => t('usage.claude.appLogin');
  static String get _consentMsg => t('usage.claude.appConsent');
  static String get _connect => t('usage.claude.connectApp');

  @override
  Future<void> setConsent(bool granted) async {
    consentGranted = granted;
    await _consent.write(granted);
    if (!granted) _store.forgetKey();
  }

  @override
  Future<UsageReport> load() async {
    if (!Platform.isMacOS) return report(UsageStatus.unavailable, message: t('usage.macOnly'));
    if (!consentGranted) consentGranted = await _consent.read();
    if (!consentGranted) {
      return report(UsageStatus.needsConsent, message: _consentMsg, source: _source, actionLabel: _connect);
    }
    return claudeUsageFromCookies(this, _store,
        requester: requester, source: _source, login: _login, consented: () => consentGranted);
  }
}

/// claude.ai web oturumu. Web kartı artık sahibin Chrome'unda açıldığından, Chrome kuruluysa onun
/// çerez deposundan okunur (ayrı onay). Chrome yoksa eski yerleşik web görünümü yolu kalır.
class ClaudeWebSource extends BaseSource {
  ClaudeWebSource({
    this.probe = WebProbe.run,
    ChromiumCookieStore? chromeStore,
    ConsentFlag? consent,
    this.requester = requestJson,
  })  : _injectedStore = chromeStore,
        _consent = consent ?? ConsentFlag('usage.consent.claude-web');

  final WebProbeRunner probe;
  final ConsentFlag _consent;
  final JsonRequester requester;

  // Test enjeksiyonu; yoksa onaydan SONRA keşfedilir (Local State o zaman okunur).
  final ChromiumCookieStore? _injectedStore;
  ChromiumCookieStore? _chromeStore;
  bool _discovered = false;

  @override
  String get serviceId => 'claude-web';

  @override
  String get title => 'Claude (web)';

  /// Chrome yolu doğrudan HTTP yapsa da, Chrome yoksa web görünümü yedeğine düşebildiğinden
  /// her zaman web kaynağı sırasına alınır (iki gizli görünüm çakışmasın).
  @override
  bool get usesWebView => true;

  /// macOS'ta web kartı Chrome'da açıldığından Chrome anahtarı için onay gerekir. Chrome keşfi
  /// onaydan SONRA (load içinde) yapılır; bu getter dosya okumaz.
  @override
  bool get requiresConsent => Platform.isMacOS;

  static String get _sourceChrome => t('usage.claude.chromeSource');
  static String get _sourceWeb => t('usage.claude.webSource');
  static String get _loginChrome => t('usage.claude.chromeLogin');
  static String get _loginWeb => t('usage.claude.webLogin');
  static String get _consentMsg => t('usage.claude.chromeConsent');
  static String get _connect => t('usage.claude.connectChrome');

  @override
  Future<void> setConsent(bool granted) async {
    consentGranted = granted;
    await _consent.write(granted);
    if (!granted) _chromeStore?.forgetKey();
  }

  // Chrome deposunu ONAYDAN SONRA keşfeder (Local State burada okunur), oturum boyu önbellekler.
  ChromiumCookieStore? _resolveStore() {
    if (_discovered) return _chromeStore;
    _discovered = true;
    return _chromeStore = _injectedStore ?? discoverChromeStore();
  }

  @override
  Future<UsageReport> load() async {
    if (Platform.isMacOS) {
      if (!consentGranted) consentGranted = await _consent.read();
      if (!consentGranted) {
        return report(UsageStatus.needsConsent,
            message: _consentMsg, source: _sourceChrome, actionLabel: _connect);
      }
      final store = _resolveStore(); // onaydan sonra
      if (store != null) {
        return claudeUsageFromCookies(this, store,
            requester: requester,
            source: _sourceChrome,
            login: _loginChrome,
            consented: () => consentGranted);
      }
      // macOS ama Chrome yok: web görünümü yedeğine düş.
    }
    if (!WebProbe.supported) return report(UsageStatus.unavailable, message: t('usage.notSupported'));
    final r = await probe('https://claude.ai', claudeOrgUsageJs);
    return parseClaudeWebResult(this, r, source: _sourceWeb, login: _loginWeb);
  }
}

/// Son kullanılan Chrome profilinin çerez deposu; Chrome kurulu değilse null. YALNIZ onaydan sonra
/// çağrılır (Local State burada okunur). Profil adı katı doğrulanır (yol kaçışı engellenir).
ChromiumCookieStore? discoverChromeStore() {
  if (!Platform.isMacOS) return null;
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  final base = '$home/Library/Application Support/Google/Chrome';
  if (!File('$base/Local State').existsSync()) return null;
  Object? lastUsed;
  try {
    lastUsed = dig(jsonDecode(File('$base/Local State').readAsStringSync()), ['profile', 'last_used']);
  } catch (_) {}
  final db = '$base/${chromeProfileName(lastUsed)}/Cookies';
  if (!File(db).existsSync()) return null;
  return ChromiumCookieStore(cookiesDbPath: db, safeStorageService: 'Chrome Safe Storage');
}

/// Güvenli profil klasör adı: yalnız "Default" ya da "Profile N"; başka her şeyde (../, ?, #, boşluk,
/// mutlak yol ...) "Default". Yol kaçışını kaynakta engeller.
String chromeProfileName(Object? lastUsed) =>
    (lastUsed is String && RegExp(r'^(Default|Profile \d+)$').hasMatch(lastUsed)) ? lastUsed : 'Default';

/// Chromium çerezleriyle (Claude uygulaması ya da Chrome) claude.ai kullanımını okur. Yalnız onaydan
/// sonra çağrılır; döndürdüğü rapor `connected: true` taşır (kartta "bağlantıyı kes" görünsün).
/// Cloudflare engeli ya da okunamama durumunda dürüstçe "plan bilinmiyor" (ASLA Max) döner.
Future<UsageReport> claudeUsageFromCookies(
  BaseSource owner,
  ChromiumCookieStore store, {
  required JsonRequester requester,
  required String source,
  required String login,
  required bool Function() consented,
}) async {
  UsageReport fail(String m) =>
      owner.report(UsageStatus.noData, message: m, source: source, connected: true);
  final cookies = await store.read(hosts: _claudeCookieHosts, names: _claudeCookieNames);
  // İstekten HEMEN ÖNCE onayı yeniden kontrol et: arada "bağlantıyı kes" olmuşsa çerez gönderilmez.
  if (!consented()) return fail(t('usage.claude.disconnected'));
  if (cookies == null || !cookies.any((c) => c.name == 'sessionKey')) {
    return fail(t('usage.claude.accountUnreadable'));
  }
  // Çerez değerleri yalnız istek başlığına girer; mesaja/önbelleğe/alt sürece sızmaz.
  final header = [for (final c in cookies) '${c.name}=${c.value}'].join('; ');
  final headers = {'Cookie': header, 'User-Agent': _chromeUserAgent, 'Accept': 'application/json'};
  try {
    final (c1, orgs) =
        await requester('GET', Uri.parse('https://claude.ai/api/organizations'), headers: headers);
    if (!consented()) return fail(t('usage.claude.disconnected'));
    if (c1 == 401 || c1 == 403) {
      return owner.report(UsageStatus.needsLogin, message: login, source: source, connected: true);
    }
    if (c1 != 200 || orgs is! List) return fail(t('usage.claude.verifyFail'));
    // Sohbet yetenekli kuruluşu seç; yoksa ilkine düş. (firstWhere tip tuzağına düşmeden.)
    Object? org;
    for (final o in orgs) {
      if (o is Map && (o['capabilities'] as List? ?? const []).contains('chat')) {
        org = o;
        break;
      }
    }
    org ??= orgs.isNotEmpty ? orgs.first : null;
    final uuid = dig(org, ['uuid']);
    if (uuid is! String) {
      return owner.report(UsageStatus.needsLogin, message: login, source: source, connected: true);
    }
    if (!consented()) return fail(t('usage.claude.disconnected'));
    final (c2, usage) = await requester(
        'GET', Uri.parse('https://claude.ai/api/organizations/$uuid/usage'), headers: headers);
    if (c2 != 200) return fail(t('usage.claude.usageFail'));
    final caps = dig(org, ['capabilities']);
    final plan = claudePlan(
      tier: dig(org, ['rate_limit_tier']) as String?,
      subscription: switch (caps) {
        List c when c.contains('claude_max') => 'max',
        List c when c.contains('claude_pro') => 'pro',
        _ => null,
      },
      freeIfKnown: caps is List,
    );
    final sections = parseClaudeUsage(trimClaudeUsage(usage));
    if (sections.isEmpty) {
      return owner.report(UsageStatus.noData,
          message: t('usage.err.unrecognized'), plan: plan, source: source, connected: true);
    }
    return owner.report(UsageStatus.ok, plan: plan, sections: sections, source: source, connected: true);
  } catch (_) {
    return fail(t('usage.claude.verifyFail'));
  }
}

/// `/usage` yanıtından yalnız ayrıştırmada gereken alanlar tutulur; tamamı Dart'a taşınmaz.
Object? trimClaudeUsage(Object? usage) {
  if (usage is! Map) return usage;
  const keep = {
    'five_hour',
    'seven_day',
    'seven_day_opus',
    'seven_day_sonnet',
    'limits',
    'seven_day_breakdown',
    'weekly_scoped_shares',
  };
  return {for (final k in keep) if (usage.containsKey(k)) k: usage[k]};
}

/// Sohbet yetenekli kuruluşu seçer ve `/usage`'tan YALNIZ gereken alanları döndürür; belirteç sayfadan
/// çıkmaz. Yalnız Chrome yokken yerleşik web görünümü yedeği (ClaudeWebSource) kullanır.
const claudeOrgUsageJs = r'''
const get = async (u) => {
  const r = await fetch(u, {credentials: 'include', headers: {accept: 'application/json'}});
  let b = null;
  try { b = JSON.parse(await r.text()); } catch (e) {}
  return {status: r.status, body: b};
};
const pick = (o) => o ? {five_hour: o.five_hour, seven_day: o.seven_day, seven_day_opus: o.seven_day_opus,
  seven_day_sonnet: o.seven_day_sonnet, limits: o.limits, seven_day_breakdown: o.seven_day_breakdown,
  weekly_scoped_shares: o.weekly_scoped_shares} : null;
const orgs = await get('/api/organizations');
if (orgs.status !== 200 || !Array.isArray(orgs.body)) return JSON.stringify({status: orgs.status});
const org = orgs.body.find(o => (o.capabilities || []).includes('chat')) || orgs.body[0];
if (!org) return JSON.stringify({status: 401});
const u = await get('/api/organizations/' + org.uuid + '/usage');
return JSON.stringify({status: u.status, usage: pick(u.body), tier: org.rate_limit_tier || null,
  capabilities: org.capabilities || []});
''';

/// Sonda/HTTP sonucunu rapora çevirir (test edilebilsin diye kaynaktan ayrı).
/// Plan, org capabilities'ten çıkar: claude_max/claude_pro yoksa "Ücretsiz".
UsageReport parseClaudeWebResult(
  BaseSource owner,
  Object? r, {
  required String source,
  required String login,
}) {
  final status = dig(r, ['status']);
  if (status == 401 || status == 403) {
    return owner.report(UsageStatus.needsLogin, message: login, source: source);
  }
  if (status != 200) {
    return owner.report(UsageStatus.error,
        message: t('usage.err.http', {'name': 'claude.ai', 'code': '$status'}), source: source);
  }
  final caps = dig(r, ['capabilities']);
  final plan = claudePlan(
    tier: dig(r, ['tier']) as String?,
    subscription: switch (caps) {
      List c when c.contains('claude_max') => 'max',
      List c when c.contains('claude_pro') => 'pro',
      _ => null,
    },
    freeIfKnown: caps is List,
  );
  final sections = parseClaudeUsage(dig(r, ['usage']));
  if (sections.isEmpty) {
    return owner.report(UsageStatus.noData, message: t('usage.err.unrecognized'), plan: plan, source: source);
  }
  return owner.report(UsageStatus.ok, plan: plan, sections: sections, source: source);
}

/// "default_claude_max_20x" -> "Max 20x"; abonelik adı; capabilities bilindi ama ücretli yoksa "Ücretsiz".
String? claudePlan({String? tier, String? subscription, bool freeIfKnown = false}) {
  final m = RegExp(r'max_(\d+)x').firstMatch(tier ?? '');
  if (m != null) return 'Max ${m[1]}x';
  if (subscription != null && subscription.isNotEmpty) {
    return subscription[0].toUpperCase() + subscription.substring(1);
  }
  return freeIfKnown ? t('usage.plan.free') : null;
}

/// OAuth ve claude.ai `usage` yanıtı. `limits` esas; yoksa eski alanlara düşer.
List<UsageSection> parseClaudeUsage(Object? j) {
  final breakdown = _breakdown(dig(j, ['seven_day_breakdown', 'rows']));
  final meters = <UsageMeter>[];
  final limits = dig(j, ['limits']);
  if (limits is List && limits.isNotEmpty) {
    for (final (i, l) in limits.indexed) {
      if (l is! Map) continue;
      final kind = l['kind'];
      final scope = dig(l, ['scope', 'model', 'display_name']) ?? dig(l, ['scope', 'surface', 'display_name']);
      meters.add(UsageMeter(
        label: switch (kind) {
          'session' => t('usage.claude.label.session'),
          'weekly_all' => t('usage.claude.label.weeklyAll'),
          'weekly_scoped' => t('usage.claude.label.weeklyScoped',
              {'scope': scope is String ? scope : t('usage.claude.label.scopedFallback')}),
          String k => k,
          _ => t('usage.limit'),
        },
        remaining: remainingFromUsedPercent(l['percent']),
        resetsAt: asDate(l['resets_at']),
        detail: switch (kind) {
          'weekly_all' => breakdown,
          'weekly_scoped' => _shareOf(dig(j, ['weekly_scoped_shares']), i),
          _ => null,
        },
      ));
    }
  } else {
    final legacy = [
      ('five_hour', t('usage.claude.label.session')),
      ('seven_day', t('usage.claude.label.weeklyAll')),
      ('seven_day_opus', t('usage.claude.label.weeklyScoped', {'scope': 'Opus'})),
      ('seven_day_sonnet', t('usage.claude.label.weeklyScoped', {'scope': 'Sonnet'})),
    ];
    for (final (key, label) in legacy) {
      final w = dig(j, [key]);
      if (w is! Map) continue;
      meters.add(UsageMeter(
        label: label,
        remaining: remainingFromUsedPercent(w['utilization']),
        resetsAt: asDate(w['resets_at']),
        detail: key == 'seven_day' ? breakdown : null,
      ));
    }
  }
  return meters.isEmpty ? const [] : [UsageSection(title: t('usage.claude.section.plan'), meters: meters)];
}

// Haftalık kullanımın uygulamalara dağılımı: bu bir pay, kalan değil.
String? _breakdown(Object? rows) {
  if (rows is! List) return null;
  final names = {'Chats': t('usage.chat'), 'Other': t('usage.other')};
  final parts = [
    for (final r in rows)
      if (r is Map && (asDouble(r['percent']) ?? 0) > 0)
        '${names[r['display_name']] ?? r['display_name']} '
            '${t('usage.percent', {'p': asDouble(r['percent'])!.round()})}',
  ];
  return parts.isEmpty ? null : t('usage.claude.usageThisWeek', {'parts': parts.join(' · ')});
}

String? _shareOf(Object? shares, int index) {
  if (shares is! List) return null;
  for (final s in shares) {
    if (s is Map && s['limit_index'] == index) {
      final cap = asDouble(s['allowance_percent_of_weekly']);
      if (cap != null) return t('usage.claude.shareCap', {'p': cap.round()});
    }
  }
  return null;
}
