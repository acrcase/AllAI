import 'dart:convert';
import 'dart:io';

import 'package:allai/data/installed_apps.dart';
import 'package:allai/data/services_store.dart';
import 'package:allai/l10n/l10n.dart';
import 'package:allai/models/ai_service.dart';
import 'package:allai/usage/usage_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.Tool</string>
	<key>CFBundleName</key>
	<string>Tool &amp; Co</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleName</key>
			<string>NESTED</string>
		</dict>
	</array>
	<key>LSEnvironment</key>
	<dict/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleVersion</key>
	<integer>7</integer>
	<key>CFBundleDisplayName</key>
	<string>Tool</string>
</dict>
</plist>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => L10n.instance.debugSet('tr'));

  group('plist', () {
    test('yalnız en üst sözlükteki değerler okunur, iç içe olanlar karışmaz', () {
      final m = parsePlistTopLevel(_plist);
      expect(m['CFBundleIdentifier'], 'com.example.Tool');
      expect(m['CFBundleName'], 'Tool & Co');
      expect(m['CFBundleDisplayName'], 'Tool');
      expect(m['NSHighResolutionCapable'], 'true');
      expect(m.values, isNot(contains('NESTED')));
    });

    test('ad: DisplayName > Name > klasör adı; arka plan uygulaması elenir', () {
      final info = parsePlistTopLevel(_plist);
      expect(macAppFromPlist(info, '/Applications/Tool.app')!.name, 'Tool');
      expect(macAppFromPlist({'CFBundleIdentifier': 'a.b'}, '/Applications/Foo Bar.app')!.name, 'Foo Bar');
      expect(macAppFromPlist({'CFBundleIdentifier': 'a.b', 'LSUIElement': 'true'}, '/x/A.app'), isNull);
      expect(macAppFromPlist({}, '/x/A.app'), isNull);
    });

    test('simge dosyası adı uzantısız yazılmış olabilir', () {
      expect(macIconFileName({'CFBundleIconFile': 'AppIcon'}), 'AppIcon.icns');
      expect(macIconFileName({'CFBundleIconFile': 'x.icns'}), 'x.icns');
      expect(macIconFileName({}), isNull);
    });
  });

  group('Windows komutları (saf)', () {
    test('kısayol çıktısı: yalnız .exe, kaldırıcı elenir, yinelenen tek, ada göre sıralı', () {
      final json = jsonEncode([
        {'name': 'Zoom', 'target': r'C:\Program Files\Zoom\bin\Zoom.exe'},
        {'name': 'Zoom (kısa)', 'target': r'c:\program files\zoom\bin\zoom.exe'},
        {'name': 'Uninstall Zoom', 'target': r'C:\Program Files\Zoom\uninstall.exe'},
        {'name': 'Notlar', 'target': r'C:\Windows\notes.txt'},
        {'name': 'Çalışma', 'target': r'C:\Apps\unins000.exe'},
        {'name': 'Ağ', 'target': r'C:\Apps\Net.exe'},
      ]);
      final apps = parseShortcutJson(json);
      expect([for (final a in apps) a.name], ['Ağ', 'Zoom']);
      expect(apps.every((a) => a.windows), isTrue);
    });

    test('tek nesne, boş ve bozuk çıktı', () {
      expect(parseShortcutJson('{"name":"A","target":"C:\\\\a.exe"}'), hasLength(1));
      expect(parseShortcutJson(''), isEmpty);
      expect(parseShortcutJson('Hata: erişim reddedildi'), isEmpty);
      expect(parseShortcutJson('\uFEFF[{"name":"A","target":"C:\\\\a.exe"}]'), hasLength(1));
    });

    test('PowerShell tırnağı ve kodlaması', () {
      expect(psQuote("C:\\O'Neil\\a.exe"), "'C:\\O''Neil\\a.exe'");
      // UTF-16LE: "A" -> 41 00
      expect(psEncode('A'), base64Encode([0x41, 0x00]));
      expect(windowsIconScript(r"C:\x'y\a.exe", r'C:\o.png'), contains("ExtractAssociatedIcon('C:\\x''y\\a.exe')"));
      expect(windowsPickScript("Uygulama 'seç'"), contains("'Uygulama ''seç'''"));
      expect(windowsScanScript(), allOf(contains(r'$env:ProgramData\Microsoft\Windows\Start Menu\Programs'), contains('ConvertTo-Json')));
      final args = powershellArgs('x');
      expect(args.last, psEncode('x'));
      expect(args, contains('-EncodedCommand'));
    });
  });

  group('kart ve kalıcılık', () {
    const mac = InstalledApp(name: 'Tool', id: 'com.example.Tool', path: '/Applications/Tool.app');
    const win = InstalledApp(name: 'Zoom', id: r'C:\Zoom\Zoom.exe', path: r'C:\Zoom\Zoom.exe', windows: true);

    test('kart alanları: uygulama kipi, kendi limit anahtarı, web yok', () {
      final s = mac.toService();
      expect((s.id, s.macBundleId, s.mode, s.webUrl, s.custom), ('app-com.example.Tool', 'com.example.Tool', OpenMode.app, null, true));
      expect(s.displaySubtitle, 'Uygulama');
      final w = win.toService();
      expect((w.appPath, w.macBundleId, w.canLaunch, w.canApp), (r'C:\Zoom\Zoom.exe', null, true, false));
      expect(w.id, r'app-c:\zoom\zoom.exe');
    });

    test('JSON gidiş-dönüş; eski kayıtta appPath yok', () {
      final back = AiService.fromJson(jsonDecode(jsonEncode(win.toService())) as Map<String, Object?>);
      expect((back.appPath, back.name, back.mode, back.custom), (win.path, 'Zoom', OpenMode.app, true));
      final old = mac.toService().toJson()..remove('appPath');
      expect(AiService.fromJson(old).appPath, isNull);
      expect(mac.toService().toJson().containsKey('appPath'), isFalse);
    });

    test('aynı uygulama iki kez eklenmez, kalıcıdır, limit paneline girmez', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ServicesStore.instance;
      await store.load();
      final before = store.services.length;
      expect(store.addApp(mac, icon: '/tmp/x.png'), isTrue);
      expect(store.addApp(mac), isFalse);
      // Hazır bir kartın paket kimliği de "zaten ekli" sayılır.
      final claude = store.services.firstWhere((s) => s.id == 'claude-app');
      expect(store.hasApp(InstalledApp(name: 'Claude', id: claude.macBundleId!, path: '/Applications/Claude.app')), isTrue);
      expect(store.services, hasLength(before + 1));
      await Future<void>.delayed(Duration.zero);

      await store.load();
      final s = store.services.last;
      expect((s.id, s.icon, s.mode, s.macBundleId), ('app-com.example.Tool', '/tmp/x.png', OpenMode.app, 'com.example.Tool'));
      expect(UsageRepository.instance.order, isNot(contains(s.usageKey)));

      store.remove(s.id);
      expect(store.hasApp(mac), isFalse);
    });

    test('Windows programı yinelemesi yol büyük/küçük harfinden bağımsız', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ServicesStore.instance;
      await store.load();
      store.add(win.toService());
      expect(store.hasApp(const InstalledApp(name: 'Z', id: r'c:\zoom\ZOOM.exe', path: r'c:\zoom\ZOOM.exe', windows: true)), isTrue);
      store.remove(win.toService().id);
    });
  });

  test('bu Mac\'te gerçek tarama: uygulamalar bulunur, AllAI kendisi yok', () async {
    final apps = await InstalledApps().scan();
    expect(apps, isNotEmpty);
    expect(apps.every((a) => a.id.isNotEmpty && a.name.isNotEmpty), isTrue);
    expect(apps.map((a) => a.id).toSet(), hasLength(apps.length));
  }, skip: !Platform.isMacOS);
}
