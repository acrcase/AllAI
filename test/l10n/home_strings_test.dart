// home.* çeviri anahtarları: 8 dilin hepsi dolu, yer tutucu kümeleri dil arası aynı.
import 'package:allai/l10n/l10n.dart';
import 'package:allai/models/ai_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Set<String> _placeholders(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  final rows = {
    for (final e in L10n.table.entries)
      if (e.key.startsWith('home.')) e.key: e.value,
  };

  test('home. anahtarları var', () => expect(rows, isNotEmpty));

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

  test('kayıtlı "Hesap n" alt başlığı yalnız gösterimde çevrilir', () {
    const s = AiService(
      id: 'claude-app@2', name: 'Claude', subtitle: 'Hesap 2', color: Colors.red, accent: Colors.red,
      usageKey: 'claude', profileOf: 'claude-app',
    );
    L10n.instance.debugSet('de');
    expect(s.displaySubtitle, 'Konto 2');
    expect(s.subtitle, 'Hesap 2');
    L10n.instance.debugSet('en');
  });
}
