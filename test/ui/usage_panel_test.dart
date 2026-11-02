// Kullanım limitleri düğmesi ve paneli: örnek veriyle ekran görüntüleri + davranış.
//
// Gerçek yazı tipi (SF) yüklenir; goldenlar bu makinede üretilir:
//   flutter test --update-goldens test/ui/usage_panel_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:allai/l10n/l10n.dart';
import 'package:allai/core/theme.dart';
import 'package:allai/ui/usage/usage_card.dart';
import 'package:allai/ui/usage/usage_corner.dart';
import 'package:allai/ui/usage/usage_format.dart';
import 'package:allai/ui/usage/usage_panel.dart';
import 'package:allai/ui/usage/usage_widgets.dart';
import 'package:allai/usage/usage_models.dart';
import 'package:allai/usage/usage_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _shot = ValueKey('shot');

// Sabit saat: goldenlar çalıştırıldığı güne bağlı olmasın (ör. haftalık sıfırlama tarihi).
final _now = DateTime(2026, 10, 24, 21, 0);

// m365 bilerek yok: baş harf rozeti görünsün.
const _icons = {
  'chatgpt': 'assets/icons/chatgpt.png',
  'antigravity': 'assets/icons/antigravity.png',
  'copilot': 'assets/icons/github_copilot.png',
  'gemini': 'assets/icons/gemini.png',
  'deepseek': 'assets/icons/deepseek.png',
  'claude': 'assets/icons/claude.png',
  'claude_web': 'assets/icons/claude.png',
};

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
  final text = [
    '/System/Library/Fonts/SFNS.ttf',
    '$fonts/Roboto-Regular.ttf',
  ].firstWhere((p) => File(p).existsSync());
  // Test teması Android tipografisi kullanır (Roboto); gerçek yazıyı o adla yüklüyoruz.
  await (FontLoader('Roboto')..addFont(_bytes(text))).load();
  await (FontLoader('MaterialIcons')..addFont(_bytes('$fonts/MaterialIcons-Regular.otf'))).load();
}

void _seed({bool phone = false, bool loading = false}) {
  final repo = UsageRepository.instance;
  final now = _now;
  DateTime inMin(int m) => now.add(Duration(minutes: m, seconds: 30));
  DateTime ago(int m) => now.subtract(Duration(minutes: m));
  final weekly = DateTime(now.year, now.month, now.day + 4, 18);
  final monthly = DateTime(now.year, now.month + 1, 1);

  repo.reports.clear();
  repo.order.clear();
  repo.refreshing.clear();
  repo.lastRefresh = ago(2);

  final list = <UsageReport>[
    UsageReport(
      serviceId: 'antigravity',
      title: 'Antigravity',
      status: phone ? UsageStatus.unavailable : UsageStatus.ok,
      fetchedAt: ago(2),
      plan: 'Google AI Pro',
      source: 'Antigravity yerel sunucusu',
      message: phone ? 'Antigravity bu cihazda kurulu değil.' : null,
      sections: phone
          ? const []
          : [
              UsageSection(
                title: 'Gemini modelleri',
                meters: [
                  UsageMeter(label: 'Gemini 3 Pro (High)', remaining: 0.8, resetsAt: inMin(204)),
                  UsageMeter(label: 'Gemini 3 Pro (Low)', remaining: 0.8, resetsAt: inMin(204)),
                  UsageMeter(label: 'Gemini 3 Flash', remaining: 1, resetsAt: inMin(204)),
                  UsageMeter(label: 'Gemini 3 Pro Image', remaining: 0.64, resetsAt: inMin(204)),
                  UsageMeter(label: 'Gemini 2.5 Pro', remaining: 0.95, resetsAt: inMin(204)),
                  UsageMeter(label: 'Gemini 2.5 Flash', remaining: 1, resetsAt: inMin(204)),
                  UsageMeter(label: 'Gemini 2.5 Flash Lite', remaining: 1, resetsAt: inMin(204)),
                ],
              ),
              UsageSection(
                title: 'Claude modelleri',
                meters: [
                  UsageMeter(
                    label: 'Claude Opus 5.5 (High)',
                    remaining: 0.87,
                    detail: '184 / 200 istek',
                    resetsAt: inMin(134),
                  ),
                  UsageMeter(
                    label: 'Claude Opus 5.5 (Thinking)',
                    remaining: 0.42,
                    resetsAt: inMin(134),
                  ),
                  UsageMeter(label: 'Claude Sonnet 5', remaining: 0.15, resetsAt: inMin(134)),
                  UsageMeter(
                    label: 'Claude Sonnet 5 (Thinking)',
                    remaining: 0.15,
                    resetsAt: inMin(134),
                  ),
                ],
              ),
              UsageSection(
                title: 'Diğer',
                meters: [
                  UsageMeter(label: 'GPT-OSS 120B (Medium)', remaining: 0, resetsAt: inMin(38)),
                  const UsageMeter(label: 'Sekme tamamlama', unlimited: true),
                ],
              ),
            ],
    ),
    UsageReport(
      serviceId: 'claude',
      title: 'Claude',
      status: UsageStatus.ok,
      fetchedAt: ago(1),
      plan: 'Max 20x',
      source: 'Claude Code yerel oturumu',
      sections: [
        UsageSection(
          meters: [
            UsageMeter(
              label: '5 saatlik oturum',
              remaining: 0.62,
              detail: '%38 kullanıldı',
              resetsAt: inMin(100),
            ),
            UsageMeter(label: 'Haftalık · tüm modeller', remaining: 0.58, resetsAt: weekly),
            UsageMeter(label: 'Haftalık · Opus', remaining: 0.18, resetsAt: weekly),
          ],
        ),
      ],
    ),
    UsageReport(
      serviceId: 'claude_web',
      title: 'Claude (web)',
      status: UsageStatus.needsLogin,
      fetchedAt: ago(9),
      message: 'claude.ai oturumu kapalı; limitler giriş yapınca görünür.',
    ),
    UsageReport(
      serviceId: 'copilot',
      title: 'GitHub Copilot',
      status: UsageStatus.ok,
      fetchedAt: ago(3),
      plan: 'Copilot Pro+',
      source: 'GitHub API · copilot_internal',
      sections: [
        UsageSection(
          title: 'Premium istekler',
          meters: [
            UsageMeter(
              label: 'Aylık premium istek',
              remaining: 0.31,
              detail: '465 / 1500 kaldı',
              resetsAt: monthly,
            ),
          ],
        ),
        const UsageSection(
          title: 'Model başına',
          meters: [
            UsageMeter(label: 'GPT-5 mini', unlimited: true, detail: '0x · plana dahil'),
            UsageMeter(label: 'Claude Sonnet 5', remaining: 0.31, detail: '1x çarpan'),
            UsageMeter(label: 'Gemini 3 Pro', detail: '1x · ayrı sayım yayımlanmıyor'),
          ],
        ),
      ],
    ),
    UsageReport(
      serviceId: 'gemini',
      title: 'Gemini',
      status: loading ? UsageStatus.loading : UsageStatus.ok,
      fetchedAt: ago(4),
      plan: 'Google AI Pro',
      message: 'Gemini kalan hakkı yayımlamıyor; sayılar bu uygulamadaki kullanımına göre tahmin.',
      sections: loading
          ? const []
          : [
              UsageSection(
                meters: [
                  UsageMeter(
                    label: 'Gemini 3 Pro (Thinking)',
                    remaining: 0.55,
                    estimated: true,
                    detail: '~55 / 100 istem (günlük)',
                    resetsAt: inMin(610),
                  ),
                  UsageMeter(
                    label: 'Deep Research',
                    remaining: 0.2,
                    estimated: true,
                    detail: '~4 / 20 rapor',
                    resetsAt: monthly,
                  ),
                ],
              ),
            ],
    ),
    UsageReport(
      serviceId: 'chatgpt',
      title: 'ChatGPT',
      status: UsageStatus.error,
      fetchedAt: ago(6),
      plan: 'Plus',
      message: 'chatgpt.com 15 sn içinde yanıt vermedi.',
      source: 'ChatGPT web oturumu',
    ),
    UsageReport(
      serviceId: 'deepseek',
      title: 'DeepSeek',
      status: UsageStatus.ok,
      fetchedAt: ago(5),
      plan: 'Ücretsiz',
      source: 'DeepSeek web',
      sections: const [
        UsageSection(
          meters: [
            UsageMeter(label: 'Sohbet (V3.2)', unlimited: true, detail: 'Web sohbeti ücretsiz'),
            UsageMeter(label: 'Derin düşünme (R2)', unlimited: true),
          ],
        ),
      ],
    ),
    UsageReport(
      serviceId: 'm365',
      title: 'Microsoft 365 Copilot',
      status: UsageStatus.noData,
      fetchedAt: ago(12),
      plan: 'Microsoft 365',
      message: 'Microsoft 365 Copilot kalan hakkı yayımlamıyor.',
    ),
  ];
  for (final r in list) {
    repo.reports[r.serviceId] = r;
    repo.order.add(r.serviceId);
  }
  if (loading) repo.refreshing.addAll({'gemini', 'chatgpt'});
}

/// Ana ekranın yerine: aurora lekeleri + birkaç kart (camın arkasında ne bulanıklaştığı görünsün).
class _FakeHome extends StatelessWidget {
  const _FakeHome();

  @override
  Widget build(BuildContext context) {
    Widget blob(Alignment a, Color c, double r) => Align(
      alignment: a,
      child: Container(
        width: r,
        height: r,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [c.withValues(alpha: 0.45), c.withValues(alpha: 0)]),
        ),
      ),
    );
    const names = [
      'ChatGPT',
      'Antigravity',
      'Copilot',
      'Gemini',
      'DeepSeek',
      'Claude',
      'Claude (web)',
      'M365',
    ];
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: AppColors.bg),
        blob(const Alignment(-0.8, -0.7), AppColors.accent, 900),
        blob(const Alignment(0.9, 0.6), AppColors.good, 800),
        blob(const Alignment(0.2, 1.1), AppColors.warn, 600),
        Padding(
          padding: const EdgeInsets.all(40),
          child: Wrap(
            spacing: 20,
            runSpacing: 20,
            children: [
              for (final n in names)
                Container(
                  width: 200,
                  height: 140,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.stroke),
                  ),
                  child: Text(n, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _app() => RepaintBoundary(
  key: _shot,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(),
    home: const Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          Positioned.fill(child: _FakeHome()),
          Positioned.fill(child: UsageCorner(serviceIcons: _icons)),
        ],
      ),
    ),
  ),
);

Future<void> _pumpApp(WidgetTester tester, Size size, {double dpr = 2, bool settle = true}) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app());
  settle ? await tester.pumpAndSettle() : await tester.pump(const Duration(seconds: 1));
}

// Simgeler gerçek eşzamansız çözülür; önce açıp önbelleğe al, sonra kapat.
Future<void> _warmImages(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.text('Kullanım limitleri'));
  settle ? await tester.pumpAndSettle() : await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() async {
    for (final e in find.byType(Image).evaluate()) {
      await precacheImage((e.widget as Image).image, e);
    }
  });
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  settle ? await tester.pumpAndSettle() : await tester.pump(const Duration(seconds: 1));
}

// Golden 1x karşılaştırılır. USAGE_SHOTS=<klasör> verilirse aynı kare cihaz ölçeğinde de yazılır.
Future<void> _snap(WidgetTester tester, String name) async {
  await expectLater(find.byKey(_shot), matchesGoldenFile('goldens/$name.png'));
  final dir = Platform.environment['USAGE_SHOTS'];
  if (dir == null || dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('$dir/$name@2x.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

// Çip satırı tembel kurulur; görünmeyen çipe kadar yatay kaydır.
Future<Finder> _showChip(WidgetTester tester, String id) async {
  final chip = find.byKey(ValueKey('usage-chip-$id'));
  await tester.scrollUntilVisible(
    chip,
    120,
    scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
  );
  return chip;
}

final _button = find.text('Kullanım limitleri').last;
final _panelOpen = find.byType(UsagePanel);

void main() {
  setUpAll(() => L10n.instance.debugSet('tr'));
  setUpAll(_loadFonts);
  setUpAll(() => UsageFormat.now = () => _now);

  testWidgets('masaüstü: kapalı, hover, açılış, açık, kaydırılmış, süzülmüş', (tester) async {
    _seed();
    await _pumpApp(tester, const Size(1280, 820));
    await _warmImages(tester);
    expect(_panelOpen, findsNothing);
    await _snap(tester, 'usage_closed');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.moveTo(tester.getCenter(_button));
    await tester.pumpAndSettle();
    await _snap(tester, 'usage_hover');
    await mouse.moveTo(const Offset(10, 10));
    await mouse.removePointer();

    await tester.tap(_button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    await _snap(tester, 'usage_opening');

    await tester.pumpAndSettle();
    expect(_panelOpen, findsOneWidget);
    expect(find.text('%87 kaldı'), findsOneWidget);
    expect(find.text('184 / 200 istek'), findsOneWidget);
    expect(find.text('2 sa 14 dk sonra yenilenir'), findsWidgets);
    expect(find.text('son güncelleme: 2 dk önce'), findsOneWidget);
    await _snap(tester, 'usage_open');

    final list = find.byType(SingleChildScrollView).last;
    await tester.drag(list, const Offset(0, -760));
    await tester.pumpAndSettle();
    await _snap(tester, 'usage_scrolled');

    await tester.drag(list, const Offset(0, -2400));
    await tester.pumpAndSettle();
    expect(find.text('Tekrar dene'), findsOneWidget);
    expect(find.text('Kartı açıp giriş yap'), findsOneWidget);
    await _snap(tester, 'usage_end');

    final chip = await _showChip(tester, 'copilot');
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('usage-card-claude')), findsNothing);
    expect(find.byKey(const ValueKey('usage-card-copilot')), findsOneWidget);
    expect(find.text('bilinmiyor'), findsOneWidget);
    expect(find.text('sınırsız'), findsOneWidget);
    await _snap(tester, 'usage_filter');
  });

  testWidgets('yükleniyor: iskelet, dönen yenile simgeleri', (tester) async {
    _seed(loading: true);
    // Yenileme sürerken animasyonlar sürekli döner; pumpAndSettle yerine sabit adım.
    await _pumpApp(tester, const Size(1280, 820), settle: false);
    await _warmImages(tester, settle: false);
    await tester.tap(_button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    final chip = await _showChip(tester, 'gemini');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(chip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 333));
    expect(find.text('Yenileniyor'), findsOneWidget);
    await _snap(tester, 'usage_loading');
  });

  testWidgets('telefon (390x844): taşma yok, kullanılamaz durumu', (tester) async {
    _seed(phone: true);
    await _pumpApp(tester, const Size(390, 844), dpr: 2);
    await _warmImages(tester);
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(find.text('Antigravity bu cihazda kurulu değil.'), findsOneWidget);
    await _snap(tester, 'usage_phone');
  });

  // Küçük telefon 9:16, tablet 3:4, küçük masaüstü penceresi: taşma olursa test düşer.
  for (final (name, size) in [
    ('usage_phone_small', const Size(360, 640)),
    ('usage_tablet', const Size(768, 1024)),
    ('usage_window_small', const Size(800, 560)),
  ]) {
    testWidgets('boyut $name (${size.width.toInt()}x${size.height.toInt()})', (tester) async {
      _seed();
      await _pumpApp(tester, size);
      await _warmImages(tester);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panelOpen, findsOneWidget);
      await _snap(tester, name);
    });
  }

  for (final size in const [Size(1280, 820), Size(360, 640)]) {
    testWidgets('dokunma hedefleri en az 44 px (${size.width.toInt()}x${size.height.toInt()})', (
      tester,
    ) async {
      _seed();
      await _pumpApp(tester, size);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -3000));
      await tester.pumpAndSettle();
      final targets = find.byType(Pressable).evaluate().toList();
      expect(targets.length, greaterThan(10));
      for (final e in targets) {
        final box = (e.renderObject! as RenderBox).size;
        expect(box.height, greaterThanOrEqualTo(44), reason: '${e.widget} $box');
        expect(box.width, greaterThanOrEqualTo(44), reason: '${e.widget} $box');
      }
    });
  }

  Widget cardHarness(UsageReport report, {VoidCallback? onConnect, VoidCallback? onDisconnect}) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: Scaffold(
          backgroundColor: AppColors.bg,
          body: Center(
            child: SizedBox(
              width: 420,
              child: UsageCard(
                report: report,
                icon: null,
                expanded: true,
                refreshing: false,
                onToggle: () {},
                onRefresh: () {},
                onConnect: onConnect ?? () {},
                onDisconnect: onDisconnect ?? () {},
                revealFor: (_) => const AlwaysStoppedAnimation(1.0),
                revealOffset: 0,
              ),
            ),
          ),
        ),
      );

  testWidgets('onay durumu: kaynağa özel bağla düğmesi görünür ve onConnect çağırır', (
    tester,
  ) async {
    // Gerçek kaynak/anahtarlık devreye girmesin diye UsageCard doğrudan, casus geri çağrıyla kurulur.
    var connected = 0;
    final report = UsageReport(
      serviceId: 'claude',
      title: 'Claude',
      status: UsageStatus.needsConsent,
      fetchedAt: _now,
      message: 'Claude uygulamasının oturumu bu Mac\'teki anahtarlıktan bir kez okunur...',
      source: 'Claude uygulaması hesabı',
      actionLabel: 'Claude hesabını bağla',
    );
    await tester.pumpWidget(cardHarness(report, onConnect: () => connected++));
    await tester.pumpAndSettle();

    // Plan yazılmaz (asla "Max" değil); kaynağa özel bağla düğmesi görünür.
    expect(find.text('Max 20x'), findsNothing);
    expect(find.text('Claude hesabını bağla'), findsOneWidget);
    expect(find.text('Bağlanmadı'), findsOneWidget);

    await tester.tap(find.text('Claude hesabını bağla'));
    await tester.pumpAndSettle();
    expect(connected, 1, reason: 'yalnız düğmeye basınca okuma başlar');
  });

  testWidgets('bağlı kaynakta "Bağlantıyı kes" görünür ve onDisconnect çağırır', (tester) async {
    var disconnected = 0;
    final report = UsageReport(
      serviceId: 'claude',
      title: 'Claude',
      status: UsageStatus.ok,
      fetchedAt: _now,
      plan: 'Ücretsiz',
      source: 'Claude uygulaması hesabı (claude.ai)',
      connected: true,
      sections: const [
        UsageSection(meters: [UsageMeter(label: '5 saatlik oturum', remaining: 0.6)]),
      ],
    );
    await tester.pumpWidget(cardHarness(report, onDisconnect: () => disconnected++));
    await tester.pumpAndSettle();

    expect(find.text('Bağlantıyı kes'), findsOneWidget);
    await tester.tap(find.text('Bağlantıyı kes'));
    await tester.pumpAndSettle();
    expect(disconnected, 1);
  });

  testWidgets('kapatma yolları: düğme, Esc, dışarı tıklama; kart katlama', (tester) async {
    _seed();
    await _pumpApp(tester, const Size(1280, 820));

    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(_panelOpen, findsOneWidget);
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(_panelOpen, findsNothing);

    await tester.tap(_button);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_panelOpen, findsNothing);

    await tester.tap(_button);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(120, 120));
    await tester.pumpAndSettle();
    expect(_panelOpen, findsNothing);

    // Panel içine tıklamak kapatmaz; başlığa tıklamak kartı katlar.
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(find.text('Claude Opus 5.5 (High)'), findsOneWidget);
    await tester.tap(find.text('Antigravity').last);
    await tester.pumpAndSettle();
    expect(_panelOpen, findsOneWidget);
    expect(find.text('Claude Opus 5.5 (High)'), findsNothing);

    // Katlama durumu kapat-aç arasında korunur.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(find.text('Claude Opus 5.5 (High)'), findsNothing);
  });
}
