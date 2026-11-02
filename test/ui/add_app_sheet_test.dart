import 'dart:io';
import 'dart:ui' as ui;

import 'package:allai/data/installed_apps.dart';
import 'package:allai/data/services_store.dart';
import 'package:allai/l10n/l10n.dart';
import 'package:allai/ui/home/add_service_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApps extends InstalledApps {
  _FakeApps({this.on = true, this.picked});
  final bool on;
  final InstalledApp? picked;

  @override
  bool get supported => on;

  @override
  Future<List<InstalledApp>> scan() async => const [
        InstalledApp(name: 'Notlar', id: 'com.apple.Notes', path: '/System/Applications/Notes.app'),
        InstalledApp(name: 'Çok Uzun Adlı Bir Uygulama Örneği Burada Biter Mi Bitmez Mi', id: 'com.example.very.long.bundle.identifier.value.x', path: '/Applications/X.app'),
        InstalledApp(name: 'Terminal', id: 'com.apple.Terminal', path: '/System/Applications/Utilities/Terminal.app'),
        InstalledApp(name: 'Claude', id: 'com.anthropic.claudefordesktop', path: '/Applications/Claude.app'),
      ];

  @override
  Future<AppIcon?> icon(InstalledApp app) async => null;

  @override
  Future<InstalledApp?> pick(String prompt) async => picked;
}

Future<void> _open(WidgetTester tester, InstalledApps apps) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    // Pencere Navigator'ın üst katmanında çizilir: yakalama sınırı onu da kapsamalı.
    builder: (context, child) => RepaintBoundary(key: const Key('shot'), child: child),
    home: Builder(
      builder: (context) => Scaffold(
        backgroundColor: const Color(0xFF0B0D14),
        body: TextButton(onPressed: () => showAddServiceSheet(context, apps: apps), child: const Text('aç')),
      ),
    ),
  ));
  await tester.tap(find.text('aç'));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() => L10n.instance.debugSet('tr'));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServicesStore.instance.load();
  });

  testWidgets('desteklenmeyen platformda Uygulamalar sekmesi hiç çıkmaz', (tester) async {
    await _open(tester, _FakeApps(on: false));
    expect(find.text('Uygulamalar'), findsNothing);
    expect(find.text('Kartlar'), findsNothing);
    expect(find.text('Özel bağlantı'), findsOneWidget);
  });

  testWidgets('sekme açılır, arama süzer, ekli olan gizlenir, tıklayınca kart eklenir', (tester) async {
    await _open(tester, _FakeApps());
    await tester.tap(find.text('Uygulamalar'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // tarama bitti
    expect(find.text('Notlar'), findsOneWidget);
    expect(find.text('Claude'), findsNothing); // hazır Claude kartı zaten ekli
    expect(find.text('1 uygulama zaten ana ekranda'), findsOneWidget);

    // Ekran görüntüsü (Read ile bakılır).
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
    await tester.runAsync(() async {
      final img = await boundary.toImage();
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
      final dir = Platform.environment['SHOT_DIR'];
      if (dir != null) File('$dir/ekle_uygulamalar.png').writeAsBytesSync(bytes.buffer.asUint8List());
    });

    await tester.enterText(find.byType(TextField), 'term');
    await tester.pump();
    expect(find.text('Notlar'), findsNothing);
    expect(find.text('Terminal'), findsOneWidget);

    await tester.tap(find.text('Terminal'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final added = ServicesStore.instance.services.last;
    expect((added.id, added.macBundleId), ('app-com.apple.Terminal', 'com.apple.Terminal'));
    expect(find.text('Uygulamalar'), findsNothing); // pencere kapandı
  });

  testWidgets('"Başka bir uygulama seç…" ekler; zaten ekli olanı eklemez ve uyarır', (tester) async {
    const mine = InstalledApp(name: 'Benim', id: 'com.me.App', path: '/Users/me/Apps/Benim.app');
    await _open(tester, _FakeApps(picked: mine));
    await tester.tap(find.text('Uygulamalar'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // tarama bitti
    await tester.tap(find.text('Başka bir uygulama seç…'));
    await tester.pump(const Duration(seconds: 1));
    expect(ServicesStore.instance.hasApp(mine), isTrue);

    await _open(tester, _FakeApps(picked: mine));
    await tester.tap(find.text('Uygulamalar'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1)); // tarama bitti
    final before = ServicesStore.instance.services.length;
    await tester.tap(find.text('Başka bir uygulama seç…'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Bu uygulama zaten ana ekranda.'), findsOneWidget);
    expect(ServicesStore.instance.services, hasLength(before));
  });
}
