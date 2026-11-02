import '../prompt_counter.dart';
import '../usage_models.dart';
import 'common.dart';
import '../../l10n/l10n.dart';

String get _counterSource => t('usage.counterSource');

/// Gemini (gemini.google.com): kalan hak yayımlanmıyor; plan katı + bu uygulamanın sayacı.
class GeminiSource extends BaseSource {
  GeminiSource({required this.planHint});

  /// Plan varsayımı: Antigravity'deki Google hesabının planı.
  final String? Function() planHint;

  @override
  String get serviceId => 'gemini';

  @override
  String get title => 'Gemini';

  @override
  String? get runAfter => 'antigravity';

  // Gemini uygulaması limitleri hesaplama tabanlı: 5 saatte bir yenilenir, haftalık tavanı var;
  // sayı yayımlanmıyor, yalnız plana göre kat veriliyor.
  // Kaynak: https://support.google.com/gemini/answer/16275805 ve
  // https://one.google.com/about/google-ai-plans/ (kontrol 24 Eki 2026).
  static String? _level(String? plan) => switch (plan) {
        'Google AI Plus' => t('usage.gemini.level.plus'),
        'Google AI Pro' => t('usage.gemini.level.pro'),
        'Google AI Ultra' => t('usage.gemini.level.ultra'),
        _ => null,
      };

  @override
  Future<UsageReport> load() async {
    final plan = planHint();
    final count = await PromptCounter.today(serviceId);
    return report(
      UsageStatus.noData,
      plan: plan,
      message: [
        if (plan != null) t('usage.gemini.planAssumed'),
        t('usage.gemini.noData'),
      ].join(' '),
      source: _counterSource,
      sections: [
        UsageSection(title: t('usage.gemini.section'), meters: [
          UsageMeter(
            label: t('usage.gemini.limitLabel'),
            detail: _level(plan) ?? t('usage.gemini.varies'),
          ),
          UsageMeter(
            label: t('usage.todayHere'),
            detail: t('usage.gemini.countPrompts', {'n': count}),
            estimated: true,
          ),
        ]),
      ],
    );
  }
}

/// DeepSeek: ücretsiz, resmî limit yok; bu uygulamanın sayacı.
class DeepSeekSource extends BaseSource {
  @override
  String get serviceId => 'deepseek';

  @override
  String get title => 'DeepSeek';

  @override
  Future<UsageReport> load() async {
    final count = await PromptCounter.today(serviceId);
    return report(
      UsageStatus.ok,
      plan: t('usage.plan.free'),
      source: _counterSource,
      sections: [
        UsageSection(meters: [
          UsageMeter(label: t('usage.deepseek.noLimit'), unlimited: true),
          UsageMeter(
            label: t('usage.todayHere'),
            detail: t('usage.deepseek.countMessages', {'n': count}),
            estimated: true,
          ),
        ]),
      ],
    );
  }
}
