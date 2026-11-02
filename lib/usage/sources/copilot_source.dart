import 'dart:io';

import '../usage_models.dart';
import 'common.dart';
import '../../l10n/l10n.dart';

/// GitHub Copilot: `gh auth token` ile `copilot_internal/user` kota anlık görüntüsü.
class CopilotSource extends BaseSource {
  @override
  String get serviceId => 'copilot';

  @override
  String get title => 'GitHub Copilot';

  static String get _source => t('usage.copilot.source');
  static const _ghPaths = ['/opt/homebrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh'];

  @override
  Future<UsageReport> load() async {
    if (!Platform.isMacOS) return report(UsageStatus.unavailable, message: t('usage.copilot.macGh'));
    final gh = _ghPaths.where((p) => File(p).existsSync()).firstOrNull;
    if (gh == null) return report(UsageStatus.unavailable, message: t('usage.copilot.ghMissing'));
    final token = await runForOutput(gh, ['auth', 'token']);
    if (token == null || token.isEmpty) {
      return report(UsageStatus.needsLogin,
          message: t('usage.copilot.ghLogin'), source: _source);
    }
    final (code, body) = await requestJson(
      'GET',
      Uri.parse('https://api.github.com/copilot_internal/user'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/json',
        'User-Agent': 'GitHubCopilotChat/0.30.0',
        'Editor-Version': 'vscode/1.100.0',
      },
    );
    if (code == 401) {
      return report(UsageStatus.needsLogin, message: t('usage.copilot.ghInvalid'), source: _source);
    }
    if (code == 403 || code == 404) {
      return report(UsageStatus.noData, message: t('usage.copilot.none'), source: _source);
    }
    if (code != 200) {
      return report(UsageStatus.error, message: t('usage.err.http', {'name': 'GitHub', 'code': code}), source: _source);
    }
    return parseCopilotUser(body);
  }

  /// `copilot_internal/user` yanıtını rapora çevirir.
  UsageReport parseCopilotUser(Object? body) {
    final sku = '${dig(body, ['access_type_sku']) ?? ''}';
    final plan = _plan(sku, dig(body, ['copilot_plan']));
    final resetsAt = asDate(dig(body, ['quota_reset_date_utc'])) ?? asDate(dig(body, ['quota_reset_date']));
    // Haziran 2026'dan beri aylık planlar token tabanlı "GitHub AI kredisi" ile faturalanıyor;
    // yıllık eski planlar istek + çarpanla sürüyor.
    final tokenBased = dig(body, ['token_based_billing']) == true;
    final sections = <UsageSection>[];
    String? message;

    final premium = dig(body, ['quota_snapshots', 'premium_interactions']);
    if (premium is Map) {
      final unlimited = premium['unlimited'] == true;
      final total = asDouble(premium['entitlement']);
      final left = asDouble(premium['remaining']) ?? asDouble(premium['quota_remaining']);
      final fraction = switch (asDouble(premium['percent_remaining'])) {
        final p? => (p / 100).clamp(0.0, 1.0),
        _ when left != null && total != null && total > 0 => (left / total).clamp(0.0, 1.0),
        _ => null,
      };
      sections.add(UsageSection(
        title: t(tokenBased ? 'usage.copilot.section.credit' : 'usage.copilot.section.premium'),
        meters: [
          UsageMeter(
            label: t(tokenBased ? 'usage.copilot.label.credit' : 'usage.copilot.label.premium'),
            remaining: unlimited ? null : fraction,
            unlimited: unlimited,
            resetsAt: resetsAt,
            detail: unlimited || left == null || total == null
                ? null
                : t(tokenBased ? 'usage.copilot.detail.credits' : 'usage.copilot.detail.requests',
                    {'left': _num(left), 'total': _num(total)}),
          ),
        ],
      ));
      if (!unlimited && left != null) {
        sections.add(UsageSection(
          title: t('usage.copilot.section.perModel'),
          meters: tokenBased
              ? [
                  for (final (name, input, output) in _creditPrices)
                    _creditMeter(name, input, output, left, fraction, resetsAt),
                ]
              : [
                  for (final (name, x) in _legacyMultipliers)
                    x == 0
                        ? UsageMeter(label: name, unlimited: true, detail: t('usage.copilot.included'))
                        : UsageMeter(
                            label: name,
                            remaining: fraction,
                            resetsAt: resetsAt,
                            estimated: true,
                            detail: t('usage.copilot.reqEstimate', {'n': (left / x).floor(), 'x': _num(x)}),
                          ),
                ],
        ));
        message = t(tokenBased ? 'usage.copilot.noteToken' : 'usage.copilot.noteLegacy');
        if (sku.contains('educational') || sku.contains('free')) {
          message = '$message ${t('usage.copilot.noteAuto')}';
        }
      }
    }

    final included = <UsageMeter>[
      for (final (key, label) in [
        ('completions', t('usage.copilot.completions')),
        ('chat', t('usage.chat')),
      ])
        if (dig(body, ['quota_snapshots', key]) case final Map q)
          // Kredi faturalamasında sohbet krediden düşer; "sınırsız" bayrağı yanıltır.
          if (!(key == 'chat' && tokenBased && q['unlimited'] == true))
            q['unlimited'] == true
                ? UsageMeter(label: label, unlimited: true)
                : UsageMeter(
                    label: label,
                    remaining: switch (asDouble(q['percent_remaining'])) {
                      final p? => (p / 100).clamp(0.0, 1.0),
                      _ => null,
                    },
                    resetsAt: resetsAt,
                    detail: '${_num(asDouble(q['remaining']) ?? 0)} / ${_num(asDouble(q['entitlement']) ?? 0)}',
                  ),
    ];
    if (included.isNotEmpty) sections.add(UsageSection(title: t('usage.copilot.section.included'), meters: included));

    if (sections.isEmpty) {
      return report(UsageStatus.noData, plan: plan, message: t('usage.copilot.noQuota'), source: _source);
    }
    return report(UsageStatus.ok, plan: plan, message: message, sections: sections, source: _source);
  }

  static UsageMeter _creditMeter(
      String name, double input, double output, double left, double? fraction, DateTime? resetsAt) {
    final perRequest = (_assumedInput * input + _assumedOutput * output) / 1e6 / 0.01;
    return UsageMeter(
      label: name,
      remaining: fraction,
      resetsAt: resetsAt,
      estimated: true,
      detail: t('usage.copilot.creditEstimate',
          {'n': (left / perRequest).floor(), 'c': perRequest.toStringAsFixed(1)}),
    );
  }

  static String? _plan(String sku, Object? plan) {
    if (sku.contains('educational')) return 'Copilot Student';
    if (sku.contains('free')) return 'Copilot Free';
    if (sku.contains('plus')) return 'Copilot Pro+';
    if (sku.contains('max')) return 'Copilot Max';
    return switch (plan) {
      'individual' => 'Copilot Pro',
      'business' => 'Copilot Business',
      'enterprise' => 'Copilot Enterprise',
      final String p => p,
      _ => null,
    };
  }

  static String _num(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
}

// GitHub istek başına token yayımlamıyor; kısa bir sohbet isteği varsayımı.
const _assumedInput = 8000;
const _assumedOutput = 1000;

// GitHub AI kredisi fiyatları: (model, $/1M giriş, $/1M çıkış), varsayılan katman; 1 kredi = 0,01 $.
// Kaynak: https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing
// (kontrol 24 Eki 2026; Gemini fiyatları kampanyalı, 2026 sonuna kadar).
const _creditPrices = <(String, double, double)>[
  ('GPT-6.1 Sol', 2.00, 10.00),
  ('GPT-6 Astra', 10.00, 50.00),
  ('GPT-6 Luna', 0.10, 0.50),
  ('GPT-5.6 Sol', 4.00, 20.00),
  ('GPT-5.6 Terra', 2.00, 12.00),
  ('GPT-5.6 Luna', 0.20, 1.20),
  ('GPT-5.3-Codex', 1.75, 14.00),
  ('Claude Fable 5.1', 10.00, 50.00),
  ('Claude Opus 5.5', 4.00, 20.00),
  ('Claude Sonnet 5.5', 2.00, 10.00),
  ('Claude Haiku 5.5', 0.10, 0.50),
  ('Gemini 4 Argon', 2.00, 10.00),
  ('Gemini 3.8 Flash', 0.75, 3.75),
  ('Grok 4.7', 2.00, 6.00),
];

// Yıllık Pro/Pro+ eski (istek tabanlı) faturalama çarpanları; 0 = dahil.
// Kaynak: https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/model-multipliers-for-annual-plans
// (kontrol 24 Eki 2026).
const _legacyMultipliers = <(String, double)>[
  ('GPT-5.3-Codex', 6),
  ('GPT-5.1', 3),
  ('GPT-5.1-Codex', 3),
  ('GPT-5.1-Codex-Max', 3),
  ('GPT-5.1-Codex-Mini', 0.33),
  ('GPT-4o', 0.33),
  ('GPT-4o mini', 0.33),
  ('Claude Opus 4.8', 27),
  ('Claude Sonnet 4.6', 9),
  ('Claude Haiku 4.5', 0.33),
  ('Gemini 3 Pro', 6),
  ('MAI-Code-1.1-Flash', 0.25),
];
