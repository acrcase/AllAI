import 'dart:convert';

import 'package:allai/data/catalog.dart';
import 'package:allai/data/services_store.dart';
import 'package:allai/l10n/l10n.dart';
import 'package:allai/models/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => L10n.instance.debugSet('tr'));
  final store = ServicesStore.instance;
  const old = ['chatgpt', 'antigravity', 'copilot', 'm365-copilot', 'gemini', 'deepseek', 'claude-app', 'claude-web'];

  test('sonradan eklenen varsayılan kart eski kayda bir kez eklenir', () async {
    SharedPreferences.setMockInitialValues({
      'services.v1': jsonEncode([for (final id in old.reversed) {'id': id, 'mode': 'web'}]),
    });
    await store.load();
    // Kullanıcının sırası korunur, Kimi sona gelir.
    expect([for (final s in store.services) s.id], [...old.reversed, 'kimi']);

    store.remove('kimi');
    await Future<void>.delayed(Duration.zero);
    await store.load();
    expect(store.services.any((s) => s.id == 'kimi'), isFalse);
  });

  test('ilk açılışta bütün varsayılanlar', () async {
    SharedPreferences.setMockInitialValues({});
    await store.load();
    expect([for (final s in store.services) s.id], [for (final s in defaultServices) s.id]);
  });

  test('bozuk tek özel kart atlanır ya da onarılır; geçerli Hesap 2 kartı ve sıra kalır', () async {
    final hesap2 = {
      'id': 'claude-app@2', 'name': 'Claude', 'subtitle': 'Hesap 2', 'icon': null,
      'color': 0xFFD97757, 'accent': 0xFFF5C4A8, 'webUrl': null,
      'macBundleId': 'com.anthropic.claudefordesktop', 'mode': 'app', 'isWebBadge': false,
      'usageKey': 'claude@2', 'custom': true, 'profileOf': 'claude-app',
    };
    SharedPreferences.setMockInitialValues({
      'services.v1': jsonEncode([
        {'id': 'kimi', 'mode': 'web'},
        hesap2,
        {...hesap2, 'id': 'custom-1', 'mode': 'gelecekteki-kip', 'profileOf': null},
        {'id': 'custom-2', 'custom': true}, // zorunlu alanlar yok
      ]),
      'services.defaults.v1': [for (final s in defaultServices) s.id],
    });
    await store.load();
    expect([for (final s in store.services) s.id], ['kimi', 'claude-app@2', 'custom-1']);
    expect(store.services.last.mode, OpenMode.app, reason: 'bilinmeyen kip, kartın açabildiği kipe döner');
  });

  test('silinen başka hesabın numarası yeniden verilmez (profil klasörü yeni hesaba geçmesin)', () async {
    SharedPreferences.setMockInitialValues({});
    await store.load();
    final base = store.services.firstWhere((s) => s.id == 'claude-app');
    final a = store.addAccount(base);
    store.remove(a.id);
    await Future<void>.delayed(Duration.zero);
    await store.load(); // yeniden açılışta da sayaç korunur
    expect(store.addAccount(base).id, 'claude-app@3');
  });
}
