import 'package:allai/l10n/l10n.dart';
import 'package:allai/platform/app_dock.dart';
import 'package:flutter_test/flutter_test.dart';

Set<String> _placeholders(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  final rows = {
    for (final e in L10n.table.entries)
      if (e.key.startsWith('native.')) e.key: e.value,
  };
  final codes = [for (final l in L10n.languages) l.code];

  tearDown(() => L10n.instance.debugSet('en'));

  test('native. anahtarları var', () => expect(rows, isNotEmpty));

  test('her anahtarda 8 dilin hepsi dolu', () {
    for (final e in rows.entries) {
      for (final c in codes) {
        expect(e.value[c]?.trim(), isNotEmpty, reason: '${e.key} [$c] boş');
      }
      expect(e.value.keys.toSet().difference(codes.toSet()), isEmpty, reason: '${e.key} bilinmeyen dil');
    }
  });

  test('yer tutucu kümeleri diller arası aynı', () {
    for (final e in rows.entries) {
      final base = _placeholders(e.value['en']!);
      for (final c in codes) {
        expect(_placeholders(e.value[c]!), base, reason: '${e.key} [$c]');
      }
    }
  });

  test('menü hizmet kalıbı {n} içerir', () {
    expect(_placeholders(rows['native.menu.service']!['tr']!), {'n'});
  });

  test('hata kodu dile göre çevrilir, bilinmeyen metin aynen kalır', () {
    const codesToKeys = {
      'err.secondAccountUnsupported': 'native.err.secondAccountUnsupported',
      'err.chromeHidden': 'native.err.chromeHidden',
      'err.chromeUnresponsive': 'native.err.chromeUnresponsive',
      'err.chromeBusy': 'native.err.chromeBusy',
    };
    for (final c in ['en', 'tr', 'de', 'ar', 'es', 'fr', 'ru', 'zh']) {
      L10n.instance.debugSet(c);
      for (final e in codesToKeys.entries) {
        expect(const DockEvent('error', message: 'x').localizedMessage, 'x');
        expect(DockEvent('error', message: e.key).localizedMessage, rows[e.value]![c]);
      }
    }
    L10n.instance.debugSet('tr');
    expect(const DockEvent('error', message: 'Eski ham mesaj').localizedMessage, 'Eski ham mesaj');
    expect(const DockEvent('error', message: 'err.bilinmiyor').localizedMessage, 'err.bilinmiyor');
    expect(const DockEvent('error').localizedMessage, isNull);
  });
}
