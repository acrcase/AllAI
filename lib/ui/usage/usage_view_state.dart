import 'package:shared_preferences/shared_preferences.dart';

/// Panelin son görünümü: açılışta en son bırakılan gibi gelsin (süzgeç, katlanan kartlar, kaydırma).
class UsageViewState {
  UsageViewState({this.filter, Set<String>? collapsed, this.scroll = 0}) : collapsed = collapsed ?? {};

  static const _key = 'usage.view.v1';

  String? filter;
  final Set<String> collapsed;
  double scroll;

  static Future<UsageViewState> load() async {
    try {
      final j = (await SharedPreferences.getInstance()).getStringList(_key);
      if (j == null || j.length < 3) return UsageViewState();
      return UsageViewState(
        filter: j[0].isEmpty ? null : j[0],
        collapsed: {...j[1].split(',').where((e) => e.isNotEmpty)},
        scroll: double.tryParse(j[2]) ?? 0,
      );
    } catch (_) {
      return UsageViewState();
    }
  }

  Future<void> save() async {
    try {
      await (await SharedPreferences.getInstance())
          .setStringList(_key, [filter ?? '', collapsed.join(','), scroll.toStringAsFixed(0)]);
    } catch (_) {}
  }
}
