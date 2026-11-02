import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_service.dart';
import '../usage/usage_repository.dart';
import 'catalog.dart';
import 'installed_apps.dart';
import 'site_icon.dart';

/// Ana ekrandaki kartların sırası, açılış biçimleri ve kullanıcının eklediği kartlar.
class ServicesStore extends ChangeNotifier {
  ServicesStore._();
  static final instance = ServicesStore._();

  static const _key = 'services.v1';

  /// Kullanıcıya bir kez sunulmuş varsayılan kartlar: sonradan eklenen varsayılan (Kimi gibi)
  /// kayıtlı listeye bir kez eklenir; kullanıcı kaldırırsa geri gelmez.
  static const _seenKey = 'services.defaults.v1';
  static const _firstDefaults = {
    'chatgpt',
    'antigravity',
    'copilot',
    'm365-copilot',
    'gemini',
    'deepseek',
    'claude-app',
    'claude-web',
  };
  final List<AiService> _all = [];

  /// Kök kart başına verilmiş en büyük hesap numarası: silinen hesabın numarası (ve profil
  /// klasörü) yeni hesaba geçmesin.
  static const _seqKey = 'services.accounts.v1';
  final _seq = <String, int>{};

  /// Bu platformda gösterilebilen kartlar (Android'de yalnız web; başka hesap kartları yalnız macOS'ta;
  /// Windows'ta ayrıca eklenen programlar).
  List<AiService> get services {
    if (Platform.isMacOS) return List.unmodifiable(_all);
    return [
      for (final s in _all)
        if (Platform.isWindows && s.canLaunch)
          s
        else if (s.canWeb && !s.separateProfile)
          s.copyWith(mode: OpenMode.web),
    ];
  }

  /// Henüz eklenmemiş hazır kartlar.
  List<AiService> get addable => [
    for (final p in [...defaultServices, ...presetServices])
      if (!_all.any((s) => s.id == p.id) && (Platform.isMacOS || p.canWeb)) p,
  ];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _all.clear();
    _seq
      ..clear()
      ..addAll({
        for (final e
            in ((jsonDecode(prefs.getString(_seqKey) ?? '{}') as Map?) ?? {})
                .entries)
          if (e.value is int) e.key as String: e.value as int,
      });
    var added = false;
    if (raw == null) {
      _all.addAll(defaultServices);
    } else {
      final known = {
        for (final s in [...defaultServices, ...presetServices]) s.id: s,
      };
      try {
        for (final e
            in (jsonDecode(raw) as List).whereType<Map<String, dynamic>>()) {
          final base = known[e['id']];
          if (base != null) {
            // Hazır kartın tanımı koddan gelir; yalnız kullanıcının seçtiği açılış biçimi saklanır.
            final mode = OpenMode.values.asNameMap()[e['mode']] ?? base.mode;
            _all.add(_validMode(base.copyWith(mode: mode)));
          } else if (e['custom'] == true) {
            // Bozuk tek bir özel kart atlanır; öteki kartlar ve sıra kaybolmaz.
            try {
              final s = _validMode(AiService.fromJson(e));
              _all.add(s);
              final n = s.profileOf == null
                  ? null
                  : int.tryParse(s.id.split('@').last);
              if (n != null && n > (_seq[s.profileOf!] ?? 0)) {
                _seq[s.profileOf!] = n;
              }
            } catch (_) {}
          }
        }
        final seen = prefs.getStringList(_seenKey)?.toSet() ?? _firstDefaults;
        for (final d in defaultServices) {
          if (!seen.contains(d.id) && !_all.any((s) => s.id == d.id)) {
            _all.add(_validMode(d));
            added = true;
          }
        }
      } catch (_) {
        _all
          ..clear()
          ..addAll(defaultServices);
      }
    }
    _publish(save: added);
    _backfillIcons();
  }

  /// Simgesiz özel kartların (önceki sürümde eklenenler) simgesi ve rengi siteden çekilir.
  Future<void> _backfillIcons() async {
    for (final s in [..._all]) {
      final url = Uri.tryParse(s.webUrl ?? '');
      if (!s.custom ||
          s.icon != null ||
          s.separateProfile ||
          url == null ||
          url.host.isEmpty) {
        continue;
      }
      final found = await SiteIcon.fetch(url);
      final i = _all.indexWhere((e) => e.id == s.id);
      if (found == null || i < 0) continue;
      _all[i] = _all[i].copyWith(
        icon: found.path,
        color: found.color,
        accent: found.accent,
      );
      _publish();
    }
  }

  void reorder(int from, int to) {
    if (from == to || from < 0 || from >= _all.length) return;
    final s = _all.removeAt(from);
    _all.insert(to.clamp(0, _all.length), s);
    _publish();
  }

  /// Görünür listeye göre yeni sıra (Android'de gizli kartlar sona kalır).
  void applyOrder(List<String> ids) {
    final byId = {for (final s in _all) s.id: s};
    final next = [for (final id in ids) ?byId.remove(id), ...byId.values];
    _all
      ..clear()
      ..addAll(next);
    _publish();
  }

  void setMode(String id, OpenMode mode) {
    final i = _all.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _all[i] = _validMode(_all[i].copyWith(mode: mode));
    _publish();
  }

  void add(AiService s) {
    if (_all.any((e) => e.id == s.id)) return;
    _all.add(s);
    _publish();
  }

  /// Bu uygulama zaten bir kart mı (hazır kart dahil; ikinci hesap kartları sayılmaz).
  bool hasApp(InstalledApp a) => _all.any(
    (s) =>
        !s.separateProfile &&
        (a.windows
            ? s.appPath?.toLowerCase() == a.path.toLowerCase()
            : s.macBundleId == a.id),
  );

  /// Uygulama kartı ekler; zaten varsa eklemez ve false döner.
  bool addApp(InstalledApp a, {String? icon, Color? color, Color? accent}) {
    if (hasApp(a)) return false;
    add(a.toService(icon: icon, color: color, accent: accent));
    return true;
  }

  /// Aynı uygulamayı başka hesapla açan kart: `<kökId>@<n>`, alt başlık `Hesap <n>` (n = 2, 3…).
  /// Uygulama ayrı veri klasörüyle ayrı örnek olarak açılır. Web görünümünde ayrı oturum yok
  /// (WKWebView varsayılan veri deposu), o yüzden web adresi taşınmaz: yalnız uygulama kipi.
  AiService addAccount(AiService of) {
    final baseId = of.profileOf ?? of.id;
    final base =
        [
          ...defaultServices,
          ...presetServices,
        ].where((s) => s.id == baseId).firstOrNull ??
        of;
    var n = math.max(2, (_seq[baseId] ?? 1) + 1);
    while (_all.any((s) => s.id == '$baseId@$n')) {
      n++;
    }
    _seq[baseId] = n;
    final s = AiService(
      id: '$baseId@$n',
      name: base.name,
      subtitle: 'Hesap $n',
      icon: base.icon,
      color: base.color,
      accent: base.accent,
      macBundleId: base.macBundleId,
      mode: OpenMode.app,
      // Limit kaynakları ana hesabın kimliğiyle okur: bu anahtarın kaynağı yok, panelde satırı da yok.
      usageKey: '${base.usageKey}@$n',
      custom: true,
      profileOf: baseId,
    );
    // Aynı uygulamanın son kartının hemen arkasına.
    _all.insert(
      _all.lastIndexWhere((e) => e.id == baseId || e.profileOf == baseId) + 1,
      s,
    );
    _publish();
    return s;
  }

  void remove(String id) {
    _all.removeWhere((s) => s.id == id);
    _publish();
  }

  void resetDefaults() {
    _all
      ..clear()
      ..addAll(defaultServices);
    _publish();
  }

  AiService _validMode(AiService s) {
    if (s.mode == OpenMode.app && !s.canApp && !s.canLaunch) {
      return s.copyWith(mode: OpenMode.web);
    }
    if (s.mode == OpenMode.web && !s.canWeb) {
      return s.copyWith(mode: OpenMode.app);
    }
    return s;
  }

  void _publish({bool save = true}) {
    final keys = <String>[];
    for (final s in services) {
      if (!keys.contains(s.usageKey)) keys.add(s.usageKey);
    }
    UsageRepository.instance.setOrder(keys);
    notifyListeners();
    if (save) _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = [
      for (final s in _all)
        s.custom ? s.toJson() : {'id': s.id, 'mode': s.mode.name},
    ];
    await prefs.setString(_key, jsonEncode(list));
    await prefs.setStringList(_seenKey, [
      for (final d in defaultServices) d.id,
    ]);
    await prefs.setString(_seqKey, jsonEncode(_seq));
  }
}
