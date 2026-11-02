import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/motion.dart';
import '../core/widgets/aurora_background.dart';
import '../data/installed_apps.dart';
import '../data/services_store.dart';
import '../l10n/l10n.dart';
import '../models/ai_service.dart';
import '../platform/menu_bridge.dart';
import '../platform/window_bridge.dart';
import 'chrome/top_chrome.dart';
import 'home/frame_probe.dart';
import 'home/home_screen.dart';
import 'home/tile_grid.dart';
import 'intro/intro_screen.dart';
import 'viewer/expanding_card.dart';
import 'viewer/viewer_layer.dart';

/// Sahne: canlı zemin, ana ekran, büyüyen kart, görüntüleyici, açılış.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> with TickerProviderStateMixin {
  final _gridKey = GlobalKey<TileGridState>();
  final _viewerKey = GlobalKey<ViewerLayerState>();

  // Fare ve hover ağacı yeniden kurmaz: zemin bunları doğrudan dinler.
  final _pointer = ValueNotifier<Offset?>(null);
  final _tint = ValueNotifier<Color?>(null);
  AiService? _hover;

  /// Ana ekranın düzenleme kipi ("Düzenle" üst çubukta, kartlar ana ekranda).
  final _editing = ValueNotifier(false);

  /// Web kartları yerleşik görünümde mi (üst çubuktaki geri/ileri/yenile için).
  final _webView = ValueNotifier(false);

  /// Görüntüleyicide açık sekmeler; ana ekranın üstünde de gösterilir.
  final _openTabs = ValueNotifier<OpenTabs>((strip: const [], closing: const {}, last: null));

  late final _intro = AnimationController(vsync: this, duration: Motion.intro);
  late final _expand = AnimationController(vsync: this, duration: Motion.expand, reverseDuration: Motion.collapse);
  late final _expandCurve = CurvedAnimation(
    parent: _expand,
    curve: Motion.emphasized,
    reverseCurve: Motion.emphasized.flipped,
  );
  late final _viewerFade = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  final _introCompleter = Completer<void>();

  bool _introDone = false;
  bool _revealed = false;
  bool _viewerMounted = false;
  bool _viewerVisible = false;
  bool _checkedMotion = false;
  AiService? _active;
  Rect? _from;
  Offset? _tapAt;

  final _store = ServicesStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStore);
    L10n.instance.addListener(_syncMenuLabels);
    MenuBridge.setHandler(_onMenu);
    _syncMenu();
    _syncMenuLabels();
    if (FrameProbe.enabled) _startProbe();
    _autoOpen();
  }

  /// Görsel denetim için: `ALLAI_OPEN=<kart kimliği>[,<kimlik>…]` açılıştan sonra kartları sırayla açar;
  /// ilki büyüyerek, ötekiler sekme olarak (yalnız profil/hata ayıklama).
  Future<void> _autoOpen() async {
    final ids = kReleaseMode ? null : Platform.environment['ALLAI_OPEN']?.split(',');
    if (ids == null) return;
    await _introCompleter.future;
    for (final (n, id) in ids.indexed) {
      // Sonrakiler büyüme bittikten sonra (≈ 0,8 sn) gelsin, yoksa yok sayılır.
      await Future<void>.delayed(Duration(milliseconds: n == 0 ? 600 : 1500));
      final i = _store.services.indexWhere((s) => s.id == id.trim());
      if (!mounted) return;
      if (i >= 0) _openIndex(i);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_checkedMotion) return;
    _checkedMotion = true;
    // Sistemde "hareketi azalt" açıksa açılış yok.
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
      _revealed = true;
      _finishIntro();
    }
  }

  @override
  void dispose() {
    MenuBridge.setHandler(null);
    _store.removeListener(_onStore);
    L10n.instance.removeListener(_syncMenuLabels);
    _intro.dispose();
    _expandCurve.dispose();
    _expand.dispose();
    _viewerFade.dispose();
    _pointer.dispose();
    _tint.dispose();
    _openTabs.dispose();
    _editing.dispose();
    _webView.dispose();
    super.dispose();
  }

  void _finishIntro() {
    if (_introDone) return;
    _introDone = true;
    if (!_introCompleter.isCompleted) _introCompleter.complete();
  }

  void _updateTint() => _tint.value = _hover?.color ?? _active?.color;

  /// Açık kartın biçimi değişti ya da kart kaldırıldı; menüdeki adlar da güncellenir.
  /// Görüntüleyici açık sekmelerini güncel listeyle eşler (kaldırılan kartın sekmesi kapanır).
  void _onStore() {
    _syncMenu();
    final a = _active;
    final fresh = a == null ? null : _store.services.where((s) => s.id == a.id).firstOrNull;
    if (a != null && fresh == null) {
      _goHome();
    } else if (a != null || _viewerMounted) {
      setState(() => _active = fresh);
    }
  }

  /// Yerel menünün sabit metinleri arayüz diline göre.
  void _syncMenuLabels() {
    MenuBridge.setLabels({
      'go': t('native.menu.go'),
      'home': t('native.menu.home'),
      'reload': t('native.menu.reload'),
      'back': t('native.menu.back'),
      'forward': t('native.menu.forward'),
      'service': t('native.menu.service'),
    });
  }

  /// Yerel "Git" menüsü: aynı adlı kartlar alt başlıkla ayrılır.
  void _syncMenu() {
    final list = _store.services;
    MenuBridge.setServiceNames([
      for (final s in list) list.where((o) => o.name == s.name).length > 1 ? '${s.name} (${s.subtitle})' : s.name,
    ]);
  }

  void _onMenu(String action, int? index) {
    switch (action) {
      case 'home':
        _goHome();
      case 'reload':
        _viewerKey.currentState?.reload();
      case 'back':
        _viewerKey.currentState?.back();
      case 'forward':
        _viewerKey.currentState?.forward();
      case 'open':
        if (index != null) _openIndex(index);
    }
  }

  Widget _titleBarDrag(Widget child) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => WindowBridge.startDrag(),
    onDoubleTap: WindowBridge.toggleZoom,
    child: child,
  );

  /// Windows'ta eklenen program yerleşmez: kendi penceresinde açılır, ana ekran yerinde kalır.
  /// Açılamazsa (silinmiş/taşınmış) anlaşılır bir ileti çıkar.
  Future<bool> _launchExternal(AiService s) async {
    if (!s.canLaunch) return false;
    if (!await InstalledApps.instance.launch(s.appPath!) && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(t('home.launch_failed', {'name': s.name})),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t('home.close')))],
        ),
      );
    }
    return true;
  }

  Future<void> _open(AiService s, Rect from, {Offset? tapAt}) async {
    if (_expand.isAnimating || !_introDone) return;
    if (await _launchExternal(s)) return;
    if (_viewerVisible) return _switch(s);
    setState(() {
      _active = s;
      _from = from;
      _tapAt = tapAt;
      _hover = null;
    });
    _updateTint();
    await _expand.forward(from: 0);
    if (!mounted || _active?.id != s.id) return;
    setState(() {
      _viewerMounted = true;
      _viewerVisible = true;
    });
    await _viewerFade.forward(from: 0);
    if (mounted) setState(() {}); // büyüyen kart, zemin ve ana ekran artık çizilmez
  }

  void _switch(AiService s) {
    if (_active?.id == s.id) return;
    if (s.canLaunch) {
      _launchExternal(s);
      return;
    }
    setState(() => _active = s);
    _updateTint();
  }

  Future<void> _goHome() async {
    final a = _active;
    if (a == null || _expand.isAnimating) return;
    setState(() {
      _viewerVisible = false;
      _tapAt = null;
    });
    _viewerFade.value = 0;
    // Kart ızgarada yer değiştirmiş olabilir: güncel yerine küçül.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() => _from = _gridKey.currentState?.rectOf(a.id) ?? _from);
    await _expand.reverse();
    if (mounted) setState(() => _active = null);
    _updateTint();
  }

  void _openIndex(int i) {
    final list = _store.services;
    if (i >= list.length || !_introDone) return;
    _openService(list[i]);
  }

  void _openService(AiService s) {
    if (_viewerVisible) return _switch(s);
    final r = _gridKey.currentState?.rectOf(s.id);
    if (r != null) _open(s, r);
  }

  void _startProbe() {
    FrameProbe.start();
    FrameProbe.run(
      introDone: _introCompleter.future,
      count: _store.services.length,
      tile: (i) => _gridKey.currentState?.rectOf(_store.services[i].id),
      dive: (i) async {
        // Yalnız büyüme/küçülme ölçülür; görüntüleyici (uygulama/web) açılmaz.
        final s = _store.services[i];
        final r = _gridKey.currentState?.rectOf(s.id);
        if (r == null) return;
        setState(() {
          _active = s;
          _from = r;
          _tapAt = r.center;
        });
        _updateTint();
        await _expand.forward(from: 0);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _expand.reverse();
        if (mounted) setState(() => _active = null);
        _updateTint();
      },
    );
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final meta = Platform.isMacOS;
    return {
      for (var i = 0; i < 9; i++)
        SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: meta, control: !meta): () =>
            _openIndex(i),
      SingleActivator(LogicalKeyboardKey.digit0, meta: meta, control: !meta): _goHome,
      SingleActivator(LogicalKeyboardKey.keyR, meta: meta, control: !meta): () => _viewerKey.currentState?.reload(),
      SingleActivator(LogicalKeyboardKey.bracketLeft, meta: meta, control: !meta): () =>
          _viewerKey.currentState?.back(),
      SingleActivator(LogicalKeyboardKey.bracketRight, meta: meta, control: !meta): () =>
          _viewerKey.currentState?.forward(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final fullyOpen = _viewerVisible && _viewerFade.isCompleted;
    final services = _store.services;
    final from = _from;
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          onHover: (e) => _pointer.value = Offset(e.position.dx / size.width, e.position.dy / size.height),
          onExit: (_) => _pointer.value = null,
          child: Stack(
            children: [
              // Uygulama yerleşikken saydam delik kalsın diye tam açıkken zemin ve ana ekran çizilmez
              // (zeminin saati de durur).
              // Yerleşik uygulama için delik saydam kalır; yalnız üst çubuğun zemini (yıldızlar) çizilir.
              if (fullyOpen)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: ViewerLayerState.barHeight,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: size.width,
                      maxWidth: size.width,
                      minHeight: size.height,
                      maxHeight: size.height,
                      child: AuroraBackground(pointer: _pointer, tint: _tint, intensity: 1),
                    ),
                  ),
                ),
              if (!fullyOpen) ...[
                Positioned.fill(
                  child: AuroraBackground(pointer: _pointer, tint: _tint, intensity: _revealed ? 1 : 0.8),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _active != null,
                    child: HomeScreen(
                      revealed: _revealed,
                      reveal: _intro,
                      hideIcons: !_introDone,
                      gridKey: _gridKey,
                      hiddenId: _active?.id,
                      onOpen: (s, r) => _open(s, r, tapAt: _gridKey.currentState?.lastTap),
                      editing: _editing,
                      onHover: (s) {
                        _hover = s;
                        _updateTint();
                      },
                      // "İçine dalma": kartlar açılan kartın merkezine doğru büyüyüp silinir; başlık yerinde kalır.
                      dive: (body) => RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _expandCurve,
                          builder: (context, child) {
                            final v = _expandCurve.value;
                            if (v == 0) return child!;
                            final c = from?.center ?? size.center(Offset.zero);
                            return Opacity(
                              opacity: (1 - v * 1.2).clamp(0.0, 1.0),
                              child: Transform.scale(
                                scale: 1 + 0.09 * v,
                                alignment: Alignment(c.dx / size.width * 2 - 1, c.dy / size.height * 2 - 1),
                                child: child,
                              ),
                            );
                          },
                          child: body,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (_viewerMounted)
                Positioned.fill(
                  child: Offstage(
                    offstage: !_viewerVisible,
                    child: FadeTransition(
                      opacity: _viewerFade,
                      child: ViewerLayer(
                        key: _viewerKey,
                        active: _active,
                        visible: _viewerVisible,
                        services: services,
                        onHome: _goHome,
                        onSwitch: _switch,
                        webView: _webView,
                        openTabs: _openTabs,
                      ),
                    ),
                  ),
                ),
              if (_active != null && from != null && !fullyOpen)
                AnimatedBuilder(
                  animation: _expandCurve,
                  builder: (context, _) => ExpandingCard(
                    service: _active!,
                    from: from,
                    to: Rect.fromLTWH(
                      0,
                      ViewerLayerState.barHeight,
                      size.width,
                      size.height - ViewerLayerState.barHeight,
                    ),
                    v: _expandCurve.value,
                    tapAt: _tapAt,
                    lifted: _tapAt != null && _expand.status != AnimationStatus.reverse,
                  ),
                ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: TopChrome(
                  progress: _expandCurve,
                  revealed: _revealed,
                  services: services,
                  openTabs: _openTabs,
                  active: _active,
                  editing: _editing,
                  webView: _webView,
                  // Pencere sürükleme/büyütme yalnız macOS'ta (saydam başlık); Windows'ta yerel başlık çubuğu var.
                  drag: Platform.isMacOS ? _titleBarDrag : null,
                  onHome: _goHome,
                  onTapTab: _openService,
                  onCloseTab: (id) => _viewerKey.currentState?.close(id),
                  onTabGone: (id) => _viewerKey.currentState?.gone(id),
                  onReload: () => _viewerKey.currentState?.reload(),
                  onBack: () => _viewerKey.currentState?.back(),
                  onForward: () => _viewerKey.currentState?.forward(),
                  onAdd: (anchor, rest) async {
                    if (_viewerVisible) return _viewerKey.currentState?.showAddMenu(anchor);
                    final s = await showServiceMenu(context, anchor, rest);
                    if (s != null && mounted) _openService(s);
                  },
                ),
              ),
              if (!_introDone)
                Positioned.fill(
                  child: IntroScreen(
                    controller: _intro,
                    services: services,
                    targetOf: (id) => _gridKey.currentState?.iconRectOf(id),
                    onReveal: () => setState(() => _revealed = true),
                    onDone: () => setState(_finishIntro),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
