// Ana ekran kartları ve açılış: hata ayıklama kipinde (assertion'lar açık) hover, basma, sürükleme
// ve açılışın bütün evreleri hatasız oynuyor mu; uçuşun hedefi kartın simge yeriyle aynı mı.
import 'package:allai/core/motion.dart';
import 'package:allai/core/theme.dart';
import 'package:allai/data/catalog.dart';
import 'package:allai/l10n/l10n.dart';
import 'package:allai/ui/home/ai_tile.dart';
import 'package:allai/ui/home/tile_grid.dart';
import 'package:allai/ui/intro/intro_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(backgroundColor: AppColors.bg, body: child),
    );

Future<void> _frames(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUpAll(() => L10n.instance.debugSet('tr'));

  testWidgets('kart ızgarası: hover, basma, sürükleme hatasız; simge yeri tutarlı', (t) async {
    t.view.physicalSize = const Size(2560, 1640);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final key = GlobalKey<TileGridState>();
    final order = <List<String>>[];
    final opened = <String>[];
    await t.pumpWidget(_app(Padding(
      padding: const EdgeInsets.fromLTRB(40, 84, 40, 92),
      child: TileGrid(
        key: key,
        services: defaultServices,
        reveal: const AlwaysStoppedAnimation(1),
        editing: false,
        onOpen: (s, r) => opened.add(s.id),
        onReorder: order.add,
      ),
    )));
    await _frames(t, 3);

    final grid = key.currentState!;
    final tile = grid.rectOf('chatgpt')!;
    final icon = grid.iconRectOf('chatgpt')!;
    expect(icon, AiTile.iconRect(tile.size).shift(tile.topLeft));

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tile.center);
    await _frames(t, 30);
    for (var i = 0; i < 20; i++) {
      await mouse.moveTo(tile.center + Offset(i * 3.0, i * 2.0));
      await t.pump(const Duration(milliseconds: 8));
    }
    await _frames(t, 20);

    // Basma → açılır.
    await t.tapAt(tile.center);
    await _frames(t, 10);
    expect(opened, ['chatgpt']);
    expect(grid.lastTap, isNotNull);

    // Sürükleyip aynı yere bırak: sıra değişmez.
    final b = grid.rectOf('antigravity')!.center;
    final drag = await t.startGesture(b, kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 20; i++) {
      await drag.moveBy(const Offset(9, 4));
      await t.pump(const Duration(milliseconds: 16));
    }
    for (var i = 1; i <= 20; i++) {
      await drag.moveBy(const Offset(-9, -4));
      await t.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await _frames(t, 40);
    expect(order.single, [for (final s in defaultServices) s.id]);

    await mouse.moveTo(const Offset(5, 5));
    await _frames(t, 40);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('açılış: bütün evreler ve bitiş', (t) async {
    t.view.physicalSize = const Size(2560, 1640);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final c = AnimationController(vsync: const TestVSync(), duration: Motion.intro);
    addTearDown(c.dispose);
    var revealed = 0, done = 0;
    await t.pumpWidget(_app(IntroScreen(
      controller: c,
      services: defaultServices,
      targetOf: (id) => Rect.fromLTWH(200.0 + defaultServices.indexWhere((s) => s.id == id) * 110, 300, 82, 82),
      onReveal: () => revealed++,
      onDone: () => done++,
    )));
    // Isındırma biter (ya da 900 ms zaman aşımı), sonra açılış oynar.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    for (var i = 0; i < 260 && done == 0; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(revealed, 1);
    expect(done, 1);
    expect(c.value, 1);
  });

  testWidgets('açılış: tıklayınca atlanır, ≤ 0,7 sn içinde biter', (t) async {
    t.view.physicalSize = const Size(2560, 1640);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final c = AnimationController(vsync: const TestVSync(), duration: Motion.intro);
    addTearDown(c.dispose);
    var done = 0;
    await t.pumpWidget(_app(IntroScreen(
      controller: c,
      services: defaultServices,
      targetOf: (id) => const Rect.fromLTWH(300, 300, 82, 82),
      onReveal: () {},
      onDone: () => done++,
    )));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    while (c.value < 0.1) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.tapAt(const Offset(600, 400));
    var ms = 0;
    while (done == 0 && ms < 2000) {
      await t.pump(const Duration(milliseconds: 16));
      ms += 16;
    }
    expect(done, 1);
    expect(c.value, 1); // dalış ve uçuş atlanmaz, yalnız hızlanır
    expect(ms, lessThanOrEqualTo(700));
  });
}
