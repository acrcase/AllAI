import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'strings_core.dart';
import 'strings_home.dart';
import 'strings_native.dart';
import 'strings_usage.dart';
import 'strings_viewer.dart';

/// Arayüz dili. İlk açılışta İngilizce; seçim diske yazılır.
///
/// Kullanım: `t('home.edit')`, yer tutuculu `t('usage.meters', {'n': 3})` ("{n} limits").
/// Çeviri tabloları `strings_*.dart` dosyalarında: anahtar -> {dil kodu: metin}.
/// Eksik dilde İngilizceye, o da yoksa anahtarın kendisine düşer.
class L10n extends ChangeNotifier {
  L10n._();
  static final instance = L10n._();

  static const languages = <({String code, String name})>[
    (code: 'en', name: 'English'),
    (code: 'tr', name: 'Türkçe'),
    (code: 'de', name: 'Deutsch'),
    (code: 'ar', name: 'العربية'),
    (code: 'es', name: 'Español'),
    (code: 'fr', name: 'Français'),
    (code: 'ru', name: 'Русский'),
    (code: 'zh', name: '中文'),
  ];

  static const _key = 'lang.v1';
  static final Map<String, Map<String, String>> _table = {
    ...stringsCore,
    ...stringsHome,
    ...stringsNative,
    ...stringsUsage,
    ...stringsViewer,
  };

  String code = 'en';

  Future<void> load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      if (saved != null && languages.any((l) => l.code == saved)) code = saved;
    } catch (_) {}
  }

  Future<void> setLanguage(String next) async {
    if (next == code || !languages.any((l) => l.code == next)) return;
    code = next;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, next);
    } catch (_) {}
  }

  /// Testte: kaydetmeden dili ayarlar.
  @visibleForTesting
  void debugSet(String next) => code = next;

  String tr(String key, [Map<String, Object>? args]) {
    final row = _table[key];
    var s = row?[code] ?? row?['en'] ?? key;
    if (args != null) {
      args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
    }
    return s;
  }

  /// Tabloda eksik anahtar var mı (test için).
  @visibleForTesting
  static Map<String, Map<String, String>> get table => _table;
}

String t(String key, [Map<String, Object>? args]) => L10n.instance.tr(key, args);
