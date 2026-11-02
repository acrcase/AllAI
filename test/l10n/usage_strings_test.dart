// usage.* çeviri anahtarları: 8 dilin hepsi dolu, yer tutucu kümeleri dil arası aynı.
import 'package:allai/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

Set<String> _placeholders(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  final rows = {
    for (final e in L10n.table.entries)
      if (e.key.startsWith('usage.')) e.key: e.value,
  };

  test('usage. anahtarları var', () => expect(rows, isNotEmpty));

  test('her anahtarda 8 dil dolu', () {
    for (final e in rows.entries) {
      for (final l in L10n.languages) {
        final v = e.value[l.code];
        expect(v != null && v.trim().isNotEmpty, true, reason: '${e.key} / ${l.code} boş');
      }
      expect(e.value.keys.toSet(), L10n.languages.map((l) => l.code).toSet(), reason: '${e.key} fazla/eksik dil');
    }
  });

  test('yer tutucu kümeleri dil arası aynı', () {
    for (final e in rows.entries) {
      final en = _placeholders(e.value['en']!);
      for (final l in L10n.languages) {
        expect(_placeholders(e.value[l.code]!), en, reason: '${e.key} / ${l.code}');
      }
    }
  });

  test('tekil karşılığı olan anahtarların çoğul ikizi var', () {
    for (final k in rows.keys.where((k) => k.endsWith('.one'))) {
      expect(rows.containsKey(k.substring(0, k.length - 4)), true, reason: '$k için çoğul anahtar yok');
    }
  });

  test('İngilizce varsayılan: Türkçe karakter sızmaz', () {
    // Ürün adı/komut dışında İngilizce metinde Türkçe harf olmamalı.
    final tr = RegExp('[çğıöşüÇĞİÖŞÜ]');
    for (final e in rows.entries) {
      expect(tr.hasMatch(e.value['en']!), false, reason: '${e.key} en değerinde Türkçe harf');
    }
  });
}
