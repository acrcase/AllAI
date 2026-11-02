import 'package:allai/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

Set<String> _placeholders(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  final rows = {
    for (final e in L10n.table.entries)
      if (e.key.startsWith('viewer.')) e.key: e.value,
  };
  final codes = [for (final l in L10n.languages) l.code];

  test('viewer. anahtarları var', () => expect(rows, isNotEmpty));

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
      final en = _placeholders(e.value['en']!);
      for (final c in codes) {
        expect(_placeholders(e.value[c]!), en, reason: '${e.key} [$c] yer tutucuları en ile farklı');
      }
    }
  });
}
