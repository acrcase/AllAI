import 'package:shared_preferences/shared_preferences.dart';

/// Bu uygulamadan bugün gönderilen istem sayısı (servis başına, yerel gün anahtarıyla).
abstract final class PromptCounter {
  static Future<void> _tail = Future.value();

  static String _dayKey(String usageKey) => 'usage.prompts.$usageKey.day';
  static String _countKey(String usageKey) => 'usage.prompts.$usageKey.count';

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static Future<int> today(String usageKey) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_dayKey(usageKey)) == _today() ? (p.getInt(_countKey(usageKey)) ?? 0) : 0;
  }

  /// Sayacı bir artırır; gün değiştiyse sıfırdan başlar. Eşzamanlı çağrılar sıraya girer.
  static Future<int> increment(String usageKey) {
    final next = _tail.then((_) async {
      final p = await SharedPreferences.getInstance();
      final n = await today(usageKey) + 1;
      await p.setString(_dayKey(usageKey), _today());
      await p.setInt(_countKey(usageKey), n);
      return n;
    });
    _tail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}
