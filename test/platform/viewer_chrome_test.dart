import 'package:allai/core/theme.dart';
import 'package:allai/data/catalog.dart';
import 'package:allai/l10n/l10n.dart';
import 'package:allai/models/ai_service.dart';
import 'package:allai/ui/chrome/top_chrome.dart';
import 'package:allai/ui/viewer/viewer_layer.dart';
import 'package:allai/ui/viewer/web_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Chrome dalı: web kartı sahibin Chrome'unda (yerli `dockWeb`) açılır; izin yoksa yerleşik görünüm.
const _dock = MethodChannel('allai/dock');
const _events = EventChannel('allai/dock/events');
final _calls = <MethodCall>[];

AiService _svc(String id) => [...defaultServices, ...presetServices].firstWhere((s) => s.id == id);

class _Host extends StatefulWidget {
  const _Host({super.key, required this.initial});
  final AiService initial;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late AiService? active = widget.initial;
  bool visible = true;
  void set({AiService? a, bool? v}) => setState(() {
        if (a != null) active = a;
        if (v != null) visible = v;
      });
  final viewer = GlobalKey<ViewerLayerState>();
  final tabs = ValueNotifier<OpenTabs>((strip: const [], closing: const {}, last: null));
  final webView = ValueNotifier(false);

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          ViewerLayer(
            key: viewer,
            active: active,
            visible: visible,
            services: [...defaultServices],
            onHome: () {},
            onSwitch: (s) => set(a: s),
            openTabs: tabs,
            webView: webView,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopChrome(
              progress: const AlwaysStoppedAnimation(1),
              revealed: true,
              services: [...defaultServices],
              openTabs: tabs,
              active: active,
              editing: ValueNotifier(false),
              webView: webView,
              onHome: () {},
              onTapTab: (s) => set(a: s),
              onCloseTab: (id) => viewer.currentState?.close(id),
              onTabGone: (id) => viewer.currentState?.gone(id),
              onAdd: (anchor, rest) async => viewer.currentState?.showAddMenu(anchor),
              onReload: () {},
              onBack: () {},
              onForward: () {},
            ),
          ),
        ],
      );
}

Future<_HostState> _pump(WidgetTester t, AiService s) async {
  t.view.physicalSize = const Size(2560, 1640);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final key = GlobalKey<_HostState>();
  await t.pumpWidget(MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: _Host(key: key, initial: s))));
  return key.currentState!;
}

Future<void> _settle(WidgetTester t, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Iterable<String> get _methods => _calls.map((c) => c.method);

/// DockPane kendi izin denetimine girene dek (görüntüleyicininki birinci, DockPane'inki ikinci isTrusted).
Future<void> _untilPaneAsksTrust(WidgetTester t) async {
  for (var i = 0; i < 100 && _methods.where((m) => m == 'isTrusted').length < 2; i++) {
    await t.pump(const Duration(milliseconds: 5));
  }
  expect(_methods.where((m) => m == 'isTrusted').length, 2);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() {
    L10n.instance.debugSet('tr');
    m.setMockStreamHandler(_events, MockStreamHandler.inline(onListen: (a, s) {}));
    WebPane.debugBody = (s) => SizedBox(key: ValueKey('webview-${s.id}'));
  });
  tearDown(() => m.setMockMethodCallHandler(_dock, null));

  void mock({required bool trusted, Duration trustDelay = Duration.zero}) {
    _calls.clear();
    m.setMockMethodCallHandler(_dock, (c) async {
      _calls.add(c);
      switch (c.method) {
        case 'webInChrome' || 'isInstalled':
          return true;
        case 'isTrusted':
          await Future<void>.delayed(trustDelay);
          return trusted;
        case 'dockWeb':
          return 'docked';
      }
      return null;
    });
  }

  testWidgets('izin varsa web kartı Chrome penceresiyle açılır, × yalnız o kartı kapatır', (t) async {
    mock(trusted: true);
    final gemini = _svc('gemini');
    await _pump(t, gemini);
    await _settle(t);
    final dock = _calls.singleWhere((c) => c.method == 'dockWeb');
    expect((dock.arguments as Map)['key'], gemini.id);
    expect((dock.arguments as Map)['url'], gemini.webUrl);
    expect(find.byKey(ValueKey('webview-${gemini.id}')), findsNothing);

    t.state<ViewerLayerState>(find.byType(ViewerLayer)).close(gemini.id);
    await _settle(t, 5);
    expect(_calls.where((c) => c.method == 'close').map((c) => (c.arguments as Map)['key']), contains(gemini.id));
  });

  testWidgets('Erişilebilirlik izni yoksa yerleşik web görünümüne düşer (izin istemez)', (t) async {
    mock(trusted: false);
    await _pump(t, _svc('gemini'));
    await _settle(t);
    expect(find.byKey(const ValueKey('webview-gemini')), findsOneWidget);
    expect(find.text('İzni aç'), findsNothing);
    expect(_methods, isNot(contains('dockWeb')));
  });

  testWidgets('izin denetimi beklenirken ana ekrana dönülürse dockWeb gönderilmez', (t) async {
    mock(trusted: true, trustDelay: const Duration(milliseconds: 100));
    final host = await _pump(t, _svc('gemini'));
    await _untilPaneAsksTrust(t);
    host.set(v: false);
    await _settle(t, 10);
    expect(_methods, isNot(contains('dockWeb')));
  });

  testWidgets('izin denetimi beklenirken sekme değişirse hata fırlamaz, eski kart yerleşmez', (t) async {
    mock(trusted: true, trustDelay: const Duration(milliseconds: 100));
    final host = await _pump(t, _svc('gemini'));
    await _untilPaneAsksTrust(t);
    host.set(a: _svc('deepseek'));
    await _settle(t, 10);
    expect(t.takeException(), isNull);
    final docked = _calls.where((c) => c.method == 'dockWeb').map((c) => (c.arguments as Map)['key']);
    expect(docked, isNot(contains('gemini')));
  });
}
