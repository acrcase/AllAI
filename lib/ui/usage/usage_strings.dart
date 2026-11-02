import '../../l10n/l10n.dart';

/// Kullanım paneli metinleri. Çeviriler `lib/l10n/strings_usage.dart` içinde (`usage.` önekli).
abstract final class UsageStrings {
  static String get title => t('usage.title');
  static String get refreshAll => t('usage.refreshAll');
  static String get refreshingAll => t('usage.refreshing');
  static String get refresh => t('usage.refresh');
  static String get retry => t('usage.retry');
  static String get all => t('usage.all');
  static String get estimated => t('usage.estimated');
  static String get unlimited => t('usage.unlimited');
  static String get unknown => t('usage.unknown');
  static String get loginHint => t('usage.loginHint');
  static String get emptyTitle => t('usage.emptyTitle');
  static String get emptyBody => t('usage.emptyBody');
  static String get neverUpdated => t('usage.neverUpdated');

  static String get statusLoading => t('usage.status.loading');
  static String get statusNeedsLogin => t('usage.status.needsLogin');
  static String get statusNeedsConsent => t('usage.status.needsConsent');
  static String get statusUnavailable => t('usage.status.unavailable');
  static String get statusNoData => t('usage.status.noData');
  static String get statusError => t('usage.status.error');

  static String get defaultNeedsLogin => t('usage.default.needsLogin');
  static String get defaultNeedsConsent => t('usage.default.needsConsent');
  static String get defaultUnavailable => t('usage.default.unavailable');
  static String get defaultNoData => t('usage.default.noData');
  static String get defaultError => t('usage.default.error');
  static String get connectAccount => t('usage.connect');
  static String get disconnectAccount => t('usage.disconnect');

  static String get justNow => t('usage.justNow');
  static String get resetSoon => t('usage.resetSoon');
  static String get resetPassed => t('usage.resetPassed');

  static List<String> get months => [for (var i = 1; i <= 12; i++) t('usage.month.$i')];

  static String lastUpdated(String when) => t('usage.lastUpdated', {'when': when});
  static String updatedAgo(String when) => t('usage.updatedAgo', {'when': when});
  static String percentLeft(String pct) => t('usage.percentLeft', {'pct': pct});
  static String meterCount(int n) => t(n == 1 ? 'usage.meterCount.one' : 'usage.meterCount', {'n': n});
  static String appCount(int n) => t(n == 1 ? 'usage.summary.apps.one' : 'usage.summary.apps', {'n': n});
  static String attentionCount(int n) =>
      t(n == 1 ? 'usage.summary.attention.one' : 'usage.summary.attention', {'n': n});
  static String get noMeasuredLimit => t('usage.summary.none');
  static String lowestLeft(int pct) => t('usage.summary.lowest', {'p': pct});
  static String source(String s) => t('usage.source', {'s': s});
  static String minutesAgo(int m) => t('usage.minutesAgo', {'m': m});
  static String hoursAgo(int h) => t('usage.hoursAgo', {'h': h});
  static String daysAgo(int d) => t('usage.daysAgo', {'d': d});
  static String resetsIn(String span) => t('usage.resetsIn', {'span': span});
  static String resetsAt(String when) => t('usage.resetsAt', {'when': when});
  static String hm(int h, int m) => m == 0
      ? t('usage.hm.h', {'h': h})
      : (h == 0 ? t('usage.hm.m', {'m': m}) : t('usage.hm.hm', {'h': h, 'm': m}));
}
