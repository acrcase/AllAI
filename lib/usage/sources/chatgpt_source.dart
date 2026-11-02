import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../usage_models.dart';
import '../web_probe.dart';
import 'common.dart';
import '../../l10n/l10n.dart';

/// ChatGPT: chatgpt.com web oturumundan Codex limitleri (`backend-api/wham/usage`);
/// olmazsa Codex oturum kayıtlarındaki son bilinen limit.
///
/// `~/.codex/auth.json` belirteci KULLANILMAZ ve asla yenilenmez (Codex oturumu düşer).
class ChatGptSource extends BaseSource {
  ChatGptSource({this.probe = WebProbe.run, Directory? codexSessions})
      : _codexSessions = codexSessions ??
            (Platform.environment['HOME'] == null
                ? null
                : Directory('${Platform.environment['HOME']}/.codex/sessions'));

  final WebProbeRunner probe;
  final Directory? _codexSessions;

  @override
  String get serviceId => 'chatgpt';

  @override
  String get title => 'ChatGPT';

  @override
  bool get usesWebView => true;

  static String get _login => t('usage.chatgpt.login');

  // OpenAI sohbet mesaj hakkını yayımlamıyor; uydurma sayı yerine açık not.
  static UsageSection get _chatNote => UsageSection(title: t('usage.chatgpt.chatSection'), meters: [
        UsageMeter(label: t('usage.chatgpt.msgAllowance'), detail: t('usage.chatgpt.msgHidden')),
      ]);

  // Belirteç sayfadan çıkmaz; yalnız kullanım yanıtı döner.
  static const _js = r'''
const sr = await fetch('/api/auth/session', {credentials: 'include'});
let s = null;
try { s = await sr.json(); } catch (e) {}
if (!s || !s.accessToken) return JSON.stringify({status: sr.status === 200 ? 401 : sr.status});
let account = (s.account && s.account.id) || null;
if (!account) {
  try {
    const p = JSON.parse(atob(s.accessToken.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    account = (p['https://api.openai.com/auth'] || {}).chatgpt_account_id || null;
  } catch (e) {}
}
const headers = {Authorization: 'Bearer ' + s.accessToken, Accept: 'application/json'};
if (account) headers['ChatGPT-Account-Id'] = account;
const r = await fetch('/backend-api/wham/usage', {credentials: 'include', headers});
let b = null;
try { b = await r.json(); } catch (e) {}
return JSON.stringify({status: r.status, usage: b, plan: (s.account && s.account.planType) || null});
''';

  @override
  Future<UsageReport> load() async {
    UsageReport? web;
    if (WebProbe.supported) {
      try {
        web = parseWebResult(await probe('https://chatgpt.com', _js));
      } on WebProbeException catch (e) {
        web = report(UsageStatus.error, message: e.message);
      } on TimeoutException {
        web = report(UsageStatus.error, message: t('usage.chatgpt.webTimeout'));
      } catch (_) {
        web = report(UsageStatus.error, message: t('usage.chatgpt.webUnreadable'));
      }
    }
    if (web != null && web.status == UsageStatus.ok) return web;

    final codex = _codexSessions == null ? null : await readCodexRateLimits(_codexSessions);
    if (codex == null) return web ?? report(UsageStatus.unavailable, message: t('usage.notSupported'));
    return report(
      web?.status ?? UsageStatus.noData,
      plan: codex.plan,
      message: web?.message,
      source: t('usage.chatgpt.codexSource'),
      sections: [UsageSection(title: t('usage.chatgpt.codexLast'), meters: codex.meters), _chatNote],
    );
  }

  /// Web sondası sonucunu rapora çevirir.
  UsageReport parseWebResult(Object? r) {
    final source = t('usage.chatgpt.webSource');
    final status = dig(r, ['status']);
    if (status == 401 || status == 403) {
      return report(UsageStatus.needsLogin, message: _login, source: source);
    }
    if (status != 200) {
      return report(UsageStatus.error, message: t('usage.err.http', {'name': 'chatgpt.com', 'code': '$status'}), source: source);
    }
    final u = dig(r, ['usage']);
    final plan = chatGptPlan(dig(u, ['plan_type']) ?? dig(r, ['plan']));
    final meters = <UsageMeter>[
      ?codexWindowMeter(dig(u, ['rate_limit', 'primary_window'])),
      ?codexWindowMeter(dig(u, ['rate_limit', 'secondary_window'])),
      if (dig(u, ['additional_rate_limits']) case final List extra)
        for (final x in extra)
          for (final key in const ['primary_window', 'secondary_window'])
            ?codexWindowMeter(dig(x, ['rate_limit', key]), name: dig(x, ['limit_name']) as String?),
    ];
    final balance = asDouble(dig(u, ['credits', 'balance']));
    if (balance != null) {
      meters.add(UsageMeter(
        label: t('usage.chatgpt.credit'),
        unlimited: dig(u, ['credits', 'unlimited']) == true,
        detail: t('usage.chatgpt.balance',
            {'n': balance.toStringAsFixed(balance == balance.roundToDouble() ? 0 : 2)}),
      ));
    }
    return report(
      meters.isEmpty ? UsageStatus.noData : UsageStatus.ok,
      plan: plan,
      message: meters.isEmpty ? t('usage.chatgpt.noCodex') : null,
      source: source,
      sections: [if (meters.isNotEmpty) UsageSection(title: t('usage.chatgpt.codexLimits'), meters: meters), _chatNote],
    );
  }
}

String? chatGptPlan(Object? planType) => switch (planType) {
      'free' => 'Free',
      'go' => 'Go',
      'plus' => 'Plus',
      'pro' => 'Pro',
      'prolite' => 'Pro Lite',
      'team' => 'Team',
      'business' => 'Business',
      'enterprise' => 'Enterprise',
      'edu' => 'Edu',
      final String p when p.isNotEmpty => p,
      _ => null,
    };

/// Codex limit penceresi: web (`limit_window_seconds`, `reset_at|reset_after_seconds`) ya da
/// oturum kaydı (`window_minutes`, `resets_at`).
UsageMeter? codexWindowMeter(Object? w, {String? name, bool estimated = false, String? detail}) {
  if (w is! Map) return null;
  final seconds = asDouble(w['limit_window_seconds']) ??
      switch (asDouble(w['window_minutes'])) {
        final m? => m * 60,
        _ => null,
      };
  final resetsAt = asDate(w['reset_at'] ?? w['resets_at']) ??
      switch (asDouble(w['reset_after_seconds'])) {
        final a? => DateTime.now().add(Duration(seconds: a.round())),
        _ => null,
      };
  return UsageMeter(
    label: '${name == null ? '' : '$name · '}${_windowLabel(seconds)}',
    remaining: remainingFromUsedPercent(w['used_percent']),
    resetsAt: resetsAt,
    estimated: estimated,
    detail: detail,
  );
}

String _windowLabel(double? seconds) {
  if (seconds == null) return t('usage.limit');
  final s = seconds.round();
  if (s == 604800) return t('usage.chatgpt.window.week');
  if (s % 86400 == 0) return t('usage.chatgpt.window.days', {'n': s ~/ 86400});
  if (s % 3600 == 0) return t('usage.chatgpt.window.hours', {'n': s ~/ 3600});
  return t('usage.chatgpt.window.minutes', {'n': (s / 60).round()});
}

/// En yeni Codex oturum kayıtlarında "rate_limits" geçen son satır.
Future<({String? plan, List<UsageMeter> meters})?> readCodexRateLimits(Directory sessions) async {
  final List<File> files;
  try {
    files = sessions.existsSync() ? _newestRollouts(sessions, 30) : const [];
  } catch (_) {
    return null;
  }
  for (final file in files) {
    try {
      String? last;
      await for (final line in file.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.contains('"rate_limits":{')) last = line;
      }
      if (last == null) continue;
      final j = jsonDecode(last);
      final parsed = parseCodexRateLimits(dig(j, ['payload', 'rate_limits']), at: asDate(dig(j, ['timestamp'])));
      if (parsed != null) return parsed;
    } catch (_) {}
  }
  return null;
}

/// Oturum kaydındaki `rate_limits` nesnesi (son bilinen değer; tahmini).
({String? plan, List<UsageMeter> meters})? parseCodexRateLimits(Object? rl, {DateTime? at}) {
  if (rl is! Map) return null;
  final seen =
      at == null ? t('usage.chatgpt.lastKnown') : t('usage.chatgpt.lastData', {'date': _localDate(at)});
  final meters = <UsageMeter>[];
  for (final key in const ['primary', 'secondary']) {
    final m = codexWindowMeter(rl[key], estimated: true, detail: seen);
    if (m == null) continue;
    final reset = m.resetsAt;
    if (reset != null && reset.isBefore(DateTime.now())) {
      // Pencere o günden beri yenilendi; eski yüzde artık geçerli değil.
      meters.add(UsageMeter(label: m.label, estimated: true, detail: t('usage.chatgpt.windowRenewed')));
    } else {
      meters.add(m);
    }
  }
  if (meters.isEmpty) return null;
  return (plan: chatGptPlan(rl['plan_type']), meters: meters);
}

List<File> _newestRollouts(Directory root, int limit) {
  final out = <File>[];
  List<FileSystemEntity> desc(Directory d) => d.listSync()..sort((a, b) => b.path.compareTo(a.path));
  for (final y in desc(root).whereType<Directory>()) {
    for (final m in desc(y).whereType<Directory>()) {
      for (final d in desc(m).whereType<Directory>()) {
        for (final f in desc(d).whereType<File>()) {
          final name = f.uri.pathSegments.last;
          if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;
          out.add(f);
          if (out.length >= limit) return out;
        }
      }
    }
  }
  return out;
}

String _localDate(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return t('usage.dateTimeYear', {
    'd': l.day,
    'mon': t('usage.month.${l.month}'),
    'y': l.year,
    'time': '${two(l.hour)}:${two(l.minute)}',
  });
}
