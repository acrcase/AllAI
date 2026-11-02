import '../../l10n/l10n.dart';
import 'usage_strings.dart';

/// Yüzde ve zaman biçimleri (intl paketi olmadan; metinler çeviri tablosundan).
abstract final class UsageFormat {
  /// Testler saati sabitleyebilsin diye tek giriş noktası.
  static DateTime Function() now = DateTime.now;

  /// 0.87 -> "%87"; sıfırdan büyük ama yuvarlanınca 0 olan değer "%<1".
  static String percent(double fraction) {
    final p = (fraction.clamp(0.0, 1.0) * 100).round();
    if (p == 0 && fraction > 0) return t('usage.percentLtOne');
    return t('usage.percent', {'p': p});
  }

  /// "az önce", "2 dk önce", "3 sa önce", "2 gün önce", sonra tarih.
  static String ago(DateTime t) {
    final d = now().difference(t);
    if (d.inMinutes < 1) return UsageStrings.justNow;
    if (d.inMinutes < 60) return UsageStrings.minutesAgo(d.inMinutes);
    if (d.inHours < 24) return UsageStrings.hoursAgo(d.inHours);
    if (d.inDays < 7) return UsageStrings.daysAgo(d.inDays);
    return dateTime(t);
  }

  /// 24 saatten yakınsa göreli ("2 sa 14 dk sonra yenilenir"), uzaksa "30 Eki 18:00’de yenilenir".
  static String reset(DateTime at) {
    final d = at.difference(now());
    if (d.isNegative) return UsageStrings.resetPassed;
    if (d.inMinutes < 1) return UsageStrings.resetSoon;
    if (d.inHours < 24) {
      return UsageStrings.resetsIn(UsageStrings.hm(d.inHours, d.inMinutes % 60));
    }
    final local = at.toLocal();
    // Türkçede bulunma eki tarihe eklenir; diğer dillerde çeviri şablonu yeter.
    final suffix = L10n.instance.code == 'tr' ? '’${_locative(local)}' : '';
    return UsageStrings.resetsAt('${dateTime(local)}$suffix');
  }

  /// "30 Eki 18:00"
  static String dateTime(DateTime at) {
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return t('usage.dateTime', {'d': at.day, 'mon': UsageStrings.months[at.month - 1], 'time': '$hh:$mm'});
  }

  // Saat okunuşunun son sözcüğüne göre bulunma eki: "18:00’de", "09:30’da", "14:15’te".
  static const _ones = ['da', 'de', 'de', 'te', 'te', 'te', 'da', 'de', 'de', 'da'];
  static const _tens = ['da', 'da', 'de', 'da', 'ta', 'de'];

  static String _locative(DateTime t) {
    final n = t.minute == 0 ? t.hour : t.minute;
    if (n % 10 != 0) return _ones[n % 10];
    return _tens[n ~/ 10];
  }
}
