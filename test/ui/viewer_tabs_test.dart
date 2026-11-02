// Görüntüleyicinin üst çubuğu: yalnız açık yapay zekâlar, hover'da ×, kapatınca en son kullanılana geçiş,
// son sekme kapanınca ana ekran, "+" menüsü; ikinci hesap kartı oluşturma/silme.
// Yerli taraf sahte AppDock kanalıyla taklit edilir; web görünümü yerine düz kutu çizilir.
//
// Golden bu makinede üretilir:  flutter test --update-goldens test/ui/viewer_tabs_test.dart
// VIEWER_SHOTS=<klasör> verilirse aynı kare 2x olarak oraya da yazılır.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:allai/core/motion.dart';
import 'package:allai/core/theme.dart';
import 'package:allai/data/catalog.dart';
import 'package:allai/data/services_store.dart';
import 'package:allai/l10n/l10n.dart';
import 'package:allai/models/ai_service.dart';
import 'package:allai/ui/home/add_service_sheet.dart';
import 'package:allai/ui/home/tile_grid.dart';
import 'package:allai/core/widgets/ambient_clock.dart';
import 'package:allai/ui/chrome/top_chrome.dart';
import 'package:allai/ui/viewer/viewer_layer.dart';
import 'package:allai/ui/viewer/web_pane.dart';
import 'package:allai/usage/usage_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _dockChannel = MethodChannel('allai/dock');
const _dockEvents = EventChannel('allai/dock/events');
const _claudeBundle = 'com.anthropic.claudefordesktop';
final _calls = <MethodCall>[];

AiService _svc(String id) => [...defaultServices, ...presetServices].firstWhere((s) => s.id == id);

// --- Sahte web görünümü: oluşturma ve atılma sayılır ---
final _created = <String>[];
final _disposed = <String>[];

class _FakeWeb extends StatefulWidget {
  const _FakeWeb(this.service);
  final AiService service;
  @override
  State<_FakeWeb> createState() => _FakeWebState();
}

class _FakeWebState extends State<_FakeWeb> {
  @override
  void initState() {
    super.initState();
    _created.add(widget.service.id);
  }

  @override
  void dispose() {
    _disposed.add(widget.service.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(color: Color.lerp(AppColors.bg, widget.service.color, 0.08)!);
}

// --- Kök ekranı taklit eden kap ---
class _Host extends StatefulWidget {
  const _Host({super.key, required this.services});
  final List<AiService> services;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final viewer = GlobalKey<ViewerLayerState>();
  late List<AiService> services = widget.services;
  AiService? active;
  bool visible = false;
  int homeCalls = 0;

  void open(AiService s) => setState(() {
        active = s;
        visible = true;
      });

  void setServices(List<AiService> list, {AiService? active}) => setState(() {
        services = list;
        if (active != null) this.active = active;
      });

  // RootScreen._goHome gibi: önce görüntüleyici gizlenir, küçülme bitince etkin kart boşalır.
  Future<void> home() async {
    homeCalls++;
    setState(() => visible = false);
    await Future<void>.delayed(Motion.collapse);
    if (mounted) setState(() => active = null);
  }

  final tabs = ValueNotifier<OpenTabs>((strip: const [], closing: const {}, last: null));
  final webView = ValueNotifier(false);

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          ViewerLayer(
            key: viewer,
            active: active,
            visible: visible,
            services: services,
            onHome: home,
            onSwitch: open,
            openTabs: tabs,
            webView: webView,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _chrome(
              services: services,
              active: active,
              tabs: tabs,
              webView: webView,
              viewer: viewer,
              onHome: home,
              onSwitch: open,
            ),
          ),
        ],
      );
}

Widget _chrome({
  required List<AiService> services,
  required AiService? active,
  required ValueNotifier<OpenTabs> tabs,
  required ValueNotifier<bool> webView,
  required GlobalKey<ViewerLayerState> viewer,
  required VoidCallback onHome,
  required ValueChanged<AiService> onSwitch,
}) =>
    TopChrome(
      progress: const AlwaysStoppedAnimation(1),
      revealed: true,
      services: services,
      openTabs: tabs,
      active: active,
      editing: ValueNotifier(false),
      webView: webView,
      onHome: onHome,
      onTapTab: onSwitch,
      onCloseTab: (id) => viewer.currentState?.close(id),
      onTabGone: (id) => viewer.currentState?.gone(id),
      onAdd: (anchor, rest) async => viewer.currentState?.showAddMenu(anchor),
      onReload: () {},
      onBack: () {},
      onForward: () {},
    );


Widget _app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: Scaffold(backgroundColor: AppColors.bg, body: child),
    );

Future<_HostState> _pumpHost(WidgetTester t, List<AiService> services) async {
  t.view.physicalSize = const Size(2560, 1640);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final key = GlobalKey<_HostState>();
  await t.pumpWidget(_app(_Host(key: key, services: services)));
  return key.currentState!;
}

Future<void> _frames(WidgetTester t, [int ms = 400]) async {
  for (var i = 0; i < ms ~/ 16; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

Finder _tab(String id) => find.byKey(ValueKey('tab-$id'));
Finder _close(String id) => find.byKey(ValueKey('tab-close-$id'));

double _closeOpacity(WidgetTester t, String id) => t
    .widget<FadeTransition>(find.ancestor(of: _close(id), matching: find.byType(FadeTransition)).first)
    .opacity
    .value;

/// Şeritteki sekmelerin kimlikleri, sırasıyla (küçülmekte olanlar dahil).
List<String> _stripIds(WidgetTester t) => [
      for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String>).evaluate())
        if ((e.widget.key! as ValueKey<String>).value case final k
            when k.startsWith('tab-') && !k.startsWith('tab-close-') && k != 'tab-add')
          k.substring(4),
    ];

/// Fareyle sekmenin üstüne gelir, × belirince ona basar.
Future<void> _hoverClose(WidgetTester t, TestGesture mouse, String id) async {
  await mouse.moveTo(t.getCenter(_tab(id)));
  await _frames(t, 240);
  expect(_closeOpacity(t, id), closeTo(1, 0.01), reason: '$id üzerine gelince × görünür');
  final at = t.getCenter(_close(id));
  await mouse.moveTo(at);
  await t.pump();
  await mouse.down(at);
  await mouse.up();
  await t.pump();
}

// --- Fontlar (golden için gerçek yazı) ---
String _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  final exe = Platform.resolvedExecutable;
  final i = exe.indexOf('/bin/cache/');
  return i > 0 ? exe.substring(0, i) : '';
}

Future<ByteData> _bytes(String path) async => ByteData.sublistView(await File(path).readAsBytes());

Future<void> _loadFonts() async {
  final fonts = '${_flutterRoot()}/bin/cache/artifacts/material_fonts';
  final text = ['/System/Library/Fonts/SFNS.ttf', '$fonts/Roboto-Regular.ttf'].firstWhere((p) => File(p).existsSync());
  await (FontLoader('Roboto')..addFont(_bytes(text))).load();
  await (FontLoader('MaterialIcons')..addFont(_bytes('$fonts/MaterialIcons-Regular.otf'))).load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    L10n.instance.debugSet('tr');
    await _loadFonts();
    WebPane.debugBody = _FakeWeb.new;
    messenger.setMockStreamHandler(_dockEvents, MockStreamHandler.inline(onListen: (args, sink) {}));
  });

  setUp(() async {
    _calls.clear();
    _created.clear();
    _disposed.clear();
    messenger.setMockMethodCallHandler(_dockChannel, (call) async {
      _calls.add(call);
      return switch (call.method) {
        'isInstalled' || 'isTrusted' => true,
        'dock' => 'docked',
        'supportsProfiles' => (call.arguments as Map)['bundleId'] == _claudeBundle,
        _ => null,
      };
    });
    SharedPreferences.setMockInitialValues({});
    await ServicesStore.instance.load();
  });

  tearDown(() => messenger.setMockMethodCallHandler(_dockChannel, null));

  List<String> dockCalls(String method) => [
        for (final c in _calls)
          if (c.method == method) (c.arguments as Map)['key'] as String,
      ];

  group('sekme şeridi', () {
    testWidgets('yalnız açıklar; × ile kapat, en son kullanılana geç, son kapanınca ana ekran', (t) async {
      final host = await _pumpHost(t, defaultServices);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1200, 600));
      addTearDown(mouse.removePointer);

      for (final id in ['gemini', 'deepseek', 'claude-web']) {
        host.open(_svc(id));
        await _frames(t);
      }
      expect(_stripIds(t), ['gemini', 'deepseek', 'claude-web']);
      expect(_tab('chatgpt'), findsNothing, reason: 'açılmamış kart şeritte yok');
      expect(_created, ['gemini', 'deepseek', 'claude-web']);

      // Fare yokken × görünmez ve basılamaz: köşeye dokunmak sekmeye geçirir.
      expect(_closeOpacity(t, 'gemini'), 0);
      await t.tapAt(t.getCenter(_close('gemini')));
      await _frames(t);
      expect(host.active?.id, 'gemini');
      expect(_stripIds(t), ['gemini', 'deepseek', 'claude-web']);

      // Etkin olmayanı kapat: etkin değişmez, web görünümü atılır, simge küçülüp çıkar.
      await _hoverClose(t, mouse, 'deepseek');
      expect(host.active?.id, 'gemini');
      expect(_disposed, ['deepseek']);
      await _frames(t);
      expect(_stripIds(t), ['gemini', 'claude-web']);

      // Etkin olanı kapat: en son kullanılan diğer sekmeye geçer.
      await _hoverClose(t, mouse, 'gemini');
      expect(host.active?.id, 'claude-web');
      expect(_disposed, ['deepseek', 'gemini']);
      await _frames(t);

      // Son sekme: ana ekrana dönülür; küçülme bitince sekme geri gelmez.
      await _hoverClose(t, mouse, 'claude-web');
      expect(host.homeCalls, 1);
      await _frames(t, 600);
      expect(host.active, isNull);
      expect(host.viewer.currentState!.openIds, isEmpty);
      expect(_stripIds(t), isEmpty);
      expect(_disposed, ['deepseek', 'gemini', 'claude-web']);
      expect(dockCalls('close'), isEmpty, reason: 'web sekmeleri yerli tarafı çağırmaz');

      await mouse.moveTo(const Offset(1200, 600));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('ana ekrana dönmek kapatmaz; açık karta basınca o sekme; sınırsız canlı (LRU yok)', (t) async {
      final all = [...defaultServices, ...presetServices];
      final host = await _pumpHost(t, all);
      final web = [for (final s in all) if (s.mode == OpenMode.web) s.id];
      expect(web.length, greaterThan(6));
      for (final id in web) {
        host.open(_svc(id));
        await _frames(t, 100);
      }
      expect(_created, web);
      expect(_disposed, isEmpty);

      host.home(); // sahte zamanda beklenmez; kareler ilerletir
      await _frames(t);
      expect(host.viewer.currentState!.openIds, web);

      host.open(_svc('gemini'));
      await _frames(t);
      expect(_created, web, reason: 'açık sekmeye geçildi, yeniden yüklenmedi');
      expect(_stripIds(t), web);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('uygulama sekmesi: × AppDock.close(kart id) çağırır', (t) async {
      final host = await _pumpHost(t, defaultServices);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1200, 600));
      addTearDown(mouse.removePointer);

      host.open(_svc('claude-app'));
      await _frames(t);
      expect(dockCalls('dock'), ['claude-app']);
      host.open(_svc('gemini'));
      await _frames(t);
      host.open(_svc('chatgpt'));
      await _frames(t);
      expect(dockCalls('dock'), ['claude-app', 'chatgpt']);

      // Etkin olmayan uygulama sekmesi.
      await _hoverClose(t, mouse, 'claude-app');
      expect(dockCalls('close'), ['claude-app']);
      expect(host.active?.id, 'chatgpt');
      await _frames(t); // küçülme biter, sekmeler yerine kayar

      // Etkin uygulama sekmesi: kapatılır, en son kullanılan web sekmesine geçilir.
      _calls.clear();
      await _hoverClose(t, mouse, 'chatgpt');
      await _frames(t);
      expect(dockCalls('close'), ['chatgpt']);
      expect(_calls.map((c) => c.method), contains('hide'), reason: 'yerleşim bırakıldı');
      expect(host.active?.id, 'gemini');
      expect(_stripIds(t), ['gemini']);

      await mouse.moveTo(const Offset(1200, 600));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('kart kaldırılınca ya da biçimi değişince eski içerik kapanır', (t) async {
      final host = await _pumpHost(t, defaultServices);
      host.open(_svc('deepseek'));
      await _frames(t);
      host.open(_svc('claude-app'));
      await _frames(t);

      // Uygulama → web: uygulama kapanır, aynı sekmede web görünümü açılır.
      final asWeb = _svc('claude-app').copyWith(mode: OpenMode.web);
      host.setServices([for (final s in defaultServices) s.id == 'claude-app' ? asWeb : s], active: asWeb);
      await _frames(t);
      expect(dockCalls('close'), ['claude-app']);
      expect(_created, ['deepseek', 'claude-app']);
      expect(_stripIds(t), ['deepseek', 'claude-app']);

      // Açık kart ana ekrandan kaldırıldı: sekmesi gider.
      host.setServices([for (final s in host.services) if (s.id != 'deepseek') s]);
      await _frames(t);
      expect(_disposed, ['deepseek']);
      expect(_stripIds(t), ['claude-app']);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('"+" menüsü: yalnız açık olmayanlar; seçilen açılır; hepsi açıksa yok', (t) async {
      final two = [_svc('gemini'), _svc('deepseek'), _svc('claude-web')];
      final host = await _pumpHost(t, two);
      host.open(_svc('gemini'));
      await _frames(t);

      await t.tap(find.byKey(const ValueKey('tab-add')));
      await _frames(t);
      expect(find.byKey(const ValueKey('add-gemini')), findsNothing);
      expect(find.byKey(const ValueKey('add-deepseek')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-claude-web')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('add-deepseek')));
      await _frames(t);
      expect(host.active?.id, 'deepseek');
      expect(_stripIds(t), ['gemini', 'deepseek']);

      host.open(_svc('claude-web'));
      await _frames(t);
      expect(find.byKey(const ValueKey('tab-add')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('"+" menüsü AllAI odağı kaybedince kapanır, sekmeler yerinde kalır', (t) async {
      final host = await _pumpHost(t, [_svc('gemini'), _svc('deepseek')]);
      host.open(_svc('gemini'));
      await _frames(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.tap(find.byKey(const ValueKey('tab-add')));
      await _frames(t);
      expect(find.byKey(const ValueKey('add-deepseek')), findsOneWidget);

      // Yerleşik uygulamaya ya da masaüstüne tıklandı: tıklama Flutter'a gelmez, yalnız odak gider.
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _frames(t);
      expect(find.byKey(const ValueKey('add-deepseek')), findsNothing);
      expect(_stripIds(t), ['gemini']);
      expect(host.active?.id, 'gemini');

      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('aynı adlı kartlarda ipucu alt başlıklı', (t) async {
      final host = await _pumpHost(t, defaultServices);
      host.open(_svc('claude-web'));
      await _frames(t);
      host.open(_svc('gemini'));
      await _frames(t);
      final tips = [for (final e in find.byType(Tooltip).evaluate()) (e.widget as Tooltip).message];
      expect(tips, containsAll(['Claude (claude.ai)', 'Gemini']));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('golden: üç açık sekme, ortadakinin üzerinde fare', (t) async {
      AmbientClock.instance.debugReset();
      t.view.physicalSize = const Size(1280, 120) * 2;
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final key = GlobalKey<_HostState>();
      const shot = ValueKey('shot');
      await t.pumpWidget(RepaintBoundary(key: shot, child: _app(_Host(key: key, services: defaultServices))));
      for (final id in ['gemini', 'deepseek', 'claude-web']) {
        key.currentState!.open(_svc(id));
        await _frames(t);
      }
      await t.runAsync(() async {
        for (final e in find.byType(Image).evaluate()) {
          await precacheImage((e.widget as Image).image, e);
        }
      });
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(640, 100));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(t.getCenter(_tab('deepseek')));
      await _frames(t, 300);
      await expectLater(find.byKey(shot), matchesGoldenFile('goldens/viewer_tabs_hover.png'));
      final dir = Platform.environment['VIEWER_SHOTS'];
      if (dir != null && dir.isNotEmpty) {
        final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(shot));
        await t.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('$dir/viewer_tabs_hover@2x.png').writeAsBytes(png!.buffer.asUint8List());
        });
      }
      await mouse.moveTo(const Offset(640, 100));
      await t.pumpWidget(const SizedBox());
    });
  });

  group('başka hesap', () {
    test('kart: <kök>@n, "Hesap n", yalnız uygulama, ayrı limit anahtarı, kalıcı', () async {
      final store = ServicesStore.instance;
      final a = store.addAccount(_svc('claude-app'));
      expect(a.id, 'claude-app@2');
      expect((a.name, a.subtitle, a.profileOf, a.mode, a.custom), ('Claude', 'Hesap 2', 'claude-app', OpenMode.app, true));
      expect(a.separateProfile, isTrue);
      expect(a.canWeb, isFalse, reason: 'web görünümünde ayrı oturum yok');
      expect(a.macBundleId, _claudeBundle);
      expect(a.usageKey, 'claude@2');
      // Panel bu anahtarı tanımaz: ana hesabın verisi ikinci hesapmış gibi gösterilmez.
      expect(UsageRepository.instance.order, isNot(contains('claude@2')));

      final b = store.addAccount(a); // ikinci hesap kartından da: kök aynı
      expect(b.id, 'claude-app@3');
      final ids = [for (final s in store.services) s.id];
      expect(ids.sublist(ids.indexOf('claude-app'), ids.indexOf('claude-app') + 3), ['claude-app', 'claude-app@2', 'claude-app@3']);

      // Kaydedilip yeniden yüklenince aynı.
      await Future<void>.delayed(Duration.zero);
      await store.load();
      final back = store.services.firstWhere((s) => s.id == 'claude-app@2');
      expect((back.subtitle, back.profileOf, back.usageKey, back.canWeb, back.mode), ('Hesap 2', 'claude-app', 'claude@2', false, OpenMode.app));

      // Silinen numara yeniden verilmez: eski hesabın profil klasörü yeni karta geçmesin.
      store.remove('claude-app@2');
      expect(store.addAccount(_svc('claude-app')).id, 'claude-app@4');
    });

    testWidgets('kart menüsü: "Başka hesapla ekle" yalnız destekleyen uygulamada; kaldırırken onay + veri silme', (t) async {
      t.view.physicalSize = const Size(2560, 1640);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final store = ServicesStore.instance;
      final grid = GlobalKey<TileGridState>();
      await t.pumpWidget(_app(Padding(
        padding: const EdgeInsets.fromLTRB(40, 84, 40, 92),
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) => TileGrid(
            key: grid,
            services: store.services,
            reveal: const AlwaysStoppedAnimation(1),
            editing: false,
            onOpen: (s, r) {},
            onReorder: store.applyOrder,
            onRemove: (s) => store.remove(s.id),
          ),
        ),
      )));
      await _frames(t, 100);

      Future<void> menu(String id) async {
        await t.tapAt(grid.currentState!.rectOf(id)!.center, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
        await _frames(t);
      }

      Future<void> dismiss() async {
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(t);
      }

      for (final id in ['gemini', 'chatgpt']) {
        await menu(id);
        expect(find.text('Ana ekrandan kaldır'), findsOneWidget);
        expect(find.text('Başka hesapla ekle'), findsNothing, reason: '$id ayrı profili desteklemiyor');
        await dismiss();
      }

      await menu('claude-app');
      await t.tap(find.text('Başka hesapla ekle'));
      await _frames(t);
      expect(store.services.map((s) => s.id), contains('claude-app@2'));

      // İkinci hesap kartında web'e geçiş yok.
      await menu('claude-app@2');
      expect(find.text('Web sürümüne geç'), findsNothing);
      await t.tap(find.text('Ana ekrandan kaldır'));
      await _frames(t);
      expect(find.text("Bu hesabın oturumu ve verileri bu Mac'ten silinir."), findsOneWidget);
      await t.tap(find.text('Vazgeç'));
      await _frames(t);
      expect(store.services.map((s) => s.id), contains('claude-app@2'));
      expect(dockCalls('deleteProfile'), isEmpty);

      await menu('claude-app@2');
      await t.tap(find.text('Ana ekrandan kaldır'));
      await _frames(t);
      await t.tap(find.text('Kaldır'));
      await _frames(t);
      expect(dockCalls('deleteProfile'), ['claude-app@2']);
      expect(store.services.map((s) => s.id), isNot(contains('claude-app@2')));

      // Sıradan kart onaysız kalkar, veri silinmez.
      await menu('deepseek');
      await t.tap(find.text('Ana ekrandan kaldır'));
      await _frames(t);
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.services.map((s) => s.id), isNot(contains('deepseek')));
      expect(dockCalls('deleteProfile'), ['claude-app@2']);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('"Ekle" sayfası: Başka hesapla ekle bölümü', (t) async {
      t.view.physicalSize = const Size(2560, 1640);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(Builder(
        builder: (context) => Center(
          child: TextButton(onPressed: () => showAddServiceSheet(context), child: const Text('aç')),
        ),
      )));
      await t.tap(find.text('aç'));
      await _frames(t, 600);
      expect(find.text('Başka hesapla ekle'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-claude-app')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-chatgpt')), findsNothing);
      await t.tap(find.byKey(const ValueKey('account-claude-app')));
      await _frames(t, 600);
      final added = ServicesStore.instance.services.firstWhere((s) => s.profileOf == 'claude-app');
      expect((added.id, added.subtitle), ('claude-app@2', 'Hesap 2'));
      await t.pumpWidget(const SizedBox());
    });
  });
}
