import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../data/services_store.dart';
import '../../models/ai_service.dart';
import '../intro/intro_timing.dart';
import 'add_service_sheet.dart';
import 'ai_tile.dart';
import '../../l10n/l10n.dart';

/// Kartları ortalı ızgaraya dizer; sürükleyerek sıralama, açılışla eşzamanlı belirme,
/// hover odağı (komşu kartlar hafifçe çekilir).
class TileGrid extends StatefulWidget {
  const TileGrid({
    super.key,
    required this.services,
    required this.reveal,
    required this.editing,
    required this.onOpen,
    required this.onReorder,
    this.hideIcons = false,
    this.hiddenId,
    this.onHover,
    this.onRemove,
    this.onToggleMode,
    this.usageOf,
  });

  final List<AiService> services;

  /// Açılış denetleyicisi (0..1); kartlar [IntroTiming.bloom] ile belirir.
  final Animation<double> reveal;
  final bool editing;
  final void Function(AiService service, Rect globalRect) onOpen;
  final ValueChanged<List<String>> onReorder;

  /// Açılışta uçan simgeler henüz inmedi: kart simgeleri gizli.
  final bool hideIcons;

  /// Açılmış (büyüyen kartın kapladığı) kart ızgarada gizlenir.
  final String? hiddenId;
  final ValueChanged<AiService?>? onHover;
  final ValueChanged<AiService>? onRemove;
  final ValueChanged<AiService>? onToggleMode;
  final double? Function(AiService service)? usageOf;

  @override
  State<TileGrid> createState() => TileGridState();
}

class TileGridState extends State<TileGrid> {
  late List<String> _order = [for (final s in widget.services) s.id];
  final _keys = <String, GlobalKey>{};
  final _stackKey = GlobalKey();
  final _focus = ValueNotifier<TileFocus?>(null);
  final _dragDelta = ValueNotifier<Offset>(Offset.zero);
  _GridLayout? _layout;

  String? _dragId;
  Offset _dragPos = Offset.zero;
  String? _pressedId;
  Offset? _pressAt;
  Offset? _lastTap;

  /// Son tıklamanın ekrandaki yeri (büyüme dalgası buradan başlar).
  Offset? get lastTap => _lastTap;

  /// Prova: açılış henüz siyahken (karanlık örtünün altında, görünmez) bütün kartlar çizilir, ilk kart
  /// hover pozuna girer, komşuları itilip karartılır, zemin tonu kartın rengine kayar (bkz. [AiTile.rehearse]).
  /// Böylece ilk gerçek hover'daki Skia boru hattı derlemeleri siyah ekrana taşınır.
  late bool _rehearsing = _wantRehearse;
  bool get _wantRehearse => widget.reveal.value < IntroTiming.at(0.10);

  @override
  void initState() {
    super.initState();
    widget.reveal.addListener(_onReveal);
    if (_rehearsing) WidgetsBinding.instance.addPostFrameCallback((_) => _rehearse(true));
  }

  void _onReveal() {
    if (_rehearsing == _wantRehearse) return;
    setState(() => _rehearsing = _wantRehearse);
    _rehearse(_rehearsing);
  }

  void _rehearse(bool on) {
    final l = _layout;
    if (!mounted || l == null || l.slots.isEmpty || widget.services.isEmpty) return;
    final s = widget.services.first;
    _focus.value = on ? TileFocus(s.id, l.slots[0] + l.tile.center(Offset.zero)) : null;
    widget.onHover?.call(on ? s : null);
  }

  @override
  void didUpdateWidget(TileGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reveal != widget.reveal) {
      oldWidget.reveal.removeListener(_onReveal);
      widget.reveal.addListener(_onReveal);
    }
    if (_dragId == null) _order = [for (final s in widget.services) s.id];
  }

  @override
  void dispose() {
    widget.reveal.removeListener(_onReveal);
    _focus.dispose();
    _dragDelta.dispose();
    super.dispose();
  }

  /// Kartın ekrandaki yeri (açma/kapama animasyonu için).
  Rect? rectOf(String id) {
    final box = _keys[id]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Kart simgesinin dinlenme yeri, ekran koordinatında (hover/belirme dönüşümleri hariç).
  Rect? iconRectOf(String id) {
    final l = _layout;
    final i = _order.indexOf(id);
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (l == null || i < 0 || i >= l.slots.length || box == null || !box.attached || !box.hasSize) return null;
    return AiTile.iconRect(l.tile).shift(box.localToGlobal(l.slots[i]));
  }

  @override
  Widget build(BuildContext context) {
    final byId = {for (final s in widget.services) s.id: s};
    _order.removeWhere((id) => !byId.containsKey(id));
    return LayoutBuilder(builder: (context, c) {
      final l = _layout = _GridLayout.compute(c.biggest, _order.length);
      final ids = [..._order];
      if (_dragId != null) {
        ids
          ..remove(_dragId)
          ..add(_dragId!); // sürüklenen en üstte çizilir
      }
      return Center(
        child: SizedBox(
          width: l.width,
          height: l.height,
          child: Stack(
            key: _stackKey,
            clipBehavior: Clip.none,
            children: [
              for (final id in ids) _positioned(byId[id]!, l),
            ],
          ),
        ),
      );
    });
  }

  Widget _positioned(AiService s, _GridLayout l) {
    final index = _order.indexOf(s.id);
    final n = _order.length;
    final dragging = _dragId == s.id;
    final slot = l.slots[index];
    final pos = dragging ? _dragPos : slot;
    final key = _keys.putIfAbsent(s.id, GlobalKey.new);
    return AnimatedPositioned(
      key: ValueKey(s.id),
      left: pos.dx,
      top: pos.dy,
      width: l.tile.width,
      height: l.tile.height,
      duration: dragging ? Duration.zero : const Duration(milliseconds: 420),
      curve: Motion.emphasized,
      child: AnimatedBuilder(
        animation: widget.reveal,
        builder: (context, child) {
          final b = IntroTiming.bloom(index, n, widget.reveal.value);
          if (b >= 1 || _rehearsing) return child!;
          // Kart, yerine inen simgenin etrafında açılır (simge sabit nokta).
          final sc = 0.84 + 0.16 * Motion.springOut.transform(b);
          return Opacity(
            opacity: Curves.easeOut.transform(b),
            child: Transform.scale(scale: sc, alignment: AiTile.iconAlignment, child: child),
          );
        },
        child: KeyedSubtree(
          key: key,
          child: AnimatedOpacity(
            opacity: widget.hiddenId == s.id ? 0 : 1,
            duration: widget.hiddenId == s.id ? Duration.zero : Motion.fast,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => setState(() {
                _pressedId = s.id;
                _pressAt = d.localPosition;
              }),
              onTapCancel: () => setState(() => _pressedId = null),
              onTapUp: (d) {
                setState(() => _pressedId = null);
                if (widget.editing) return;
                _lastTap = d.globalPosition;
                final r = rectOf(s.id);
                if (r != null) widget.onOpen(s, r);
              },
              onSecondaryTapUp: (d) => _menu(s, d.globalPosition),
              onPanStart: (_) => setState(() {
                _dragId = s.id;
                _dragPos = slot;
                _pressedId = null;
                _focus.value = null;
              }),
              onPanUpdate: (d) => _dragTo(d.delta, l),
              onPanEnd: (_) => _drop(),
              onPanCancel: _drop,
              child: AiTile(
                service: s,
                size: l.tile,
                center: slot + l.tile.center(Offset.zero),
                focus: _focus,
                dragDelta: _dragDelta,
                editing: widget.editing,
                lifted: dragging,
                pressed: _pressedId == s.id,
                pressAt: _pressedId == s.id ? _pressAt : null,
                dimmed: _dragId != null && !dragging,
                hideIcon: widget.hideIcons && !_rehearsing,
                rehearse: _rehearsing && index == 0,
                lowestRemaining: widget.usageOf?.call(s),
                jigglePhase: (index * 0.37) % 1,
                onHoverChanged: (h) => _onHover(s, h, slot + l.tile.center(Offset.zero)),
                // Düzenle kipindeki ✕: sağ tık menüsüyle aynı yol (başka hesap kartında önce onay, verisi silinir).
                onRemove: widget.onRemove == null
                    ? null
                    : () async {
                        if (await confirmDeleteAccount(context, s) && mounted) widget.onRemove?.call(s);
                      },
                onToggleMode: widget.onToggleMode == null ? null : () => widget.onToggleMode!(s),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onHover(AiService s, bool h, Offset center) {
    if (h) {
      if (_dragId == null) _focus.value = TileFocus(s.id, center);
    } else if (_focus.value?.id == s.id) {
      _focus.value = null;
    }
    widget.onHover?.call(h ? s : null);
  }

  void _dragTo(Offset delta, _GridLayout l) {
    final id = _dragId;
    if (id == null) return;
    _dragPos += delta;
    _dragDelta.value = delta;
    final center = _dragPos + l.tile.center(Offset.zero);
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < l.slots.length; i++) {
      final d = (l.slots[i] + l.tile.center(Offset.zero) - center).distanceSquared;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    setState(() {
      if (_order.indexOf(id) != best) {
        _order
          ..remove(id)
          ..insert(best, id);
      }
    });
  }

  void _drop() {
    if (_dragId == null) return;
    setState(() => _dragId = null);
    _dragDelta.value = Offset.zero;
    widget.onReorder([..._order]);
  }

  Future<void> _menu(AiService s, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final both = s.canApp && s.canWeb;
    final account = await canAddAccount(s);
    if (!mounted) return;
    final choice = await showMenu<String>(
      context: context,
      color: AppColors.bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.stroke),
      ),
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'open', child: Text(t('home.menu_open'))),
        if (both)
          PopupMenuItem(
            value: 'mode',
            child: Text(s.mode == OpenMode.app ? t('home.switch_web') : t('home.switch_app')),
          ),
        if (account) PopupMenuItem(value: 'account', child: Text(t('home.account_add'))),
        PopupMenuItem(value: 'remove', child: Text(t('home.remove'))),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'open':
        _lastTap = null;
        final r = rectOf(s.id);
        if (r != null) widget.onOpen(s, r);
      case 'mode':
        widget.onToggleMode?.call(s);
      case 'account':
        ServicesStore.instance.addAccount(s);
      case 'remove':
        // Başka hesap kartında önce onay; verisi de silinir.
        if (await confirmDeleteAccount(context, s) && mounted) widget.onRemove?.call(s);
    }
  }
}

class _GridLayout {
  const _GridLayout(this.tile, this.slots, this.width, this.height);

  final Size tile;
  final List<Offset> slots;
  final double width;
  final double height;

  static _GridLayout compute(Size box, int n) {
    if (n == 0) return const _GridLayout(Size(212, 236), [], 0, 0);
    var tileW = 212.0, tileH = 236.0, gap = 24.0;
    // 9–10 kart 5 + 4/5 dizilir: geniş pencerede kartlar küçülmez (3×3'te yükseklik sınırına takılıyordu).
    var cols = n <= 4 ? n : (n == 5 || n == 6 ? 3 : (n == 9 || n == 10 ? 5 : 4));
    final fit = ((box.width + gap) / (tileW * 0.72 + gap)).floor();
    cols = cols.clamp(1, math.max(1, fit));
    final rows = (n / cols).ceil();
    final needW = cols * tileW + (cols - 1) * gap;
    final needH = rows * tileH + (rows - 1) * gap;
    final k = math.min(1.0, math.min(box.width / needW, box.height / needH)).clamp(0.62, 1.0);
    tileW *= k;
    tileH *= k;
    gap *= k;
    final gridW = cols * tileW + (cols - 1) * gap;
    final gridH = rows * tileH + (rows - 1) * gap;
    final slots = <Offset>[];
    for (var i = 0; i < n; i++) {
      final row = i ~/ cols, col = i % cols;
      final inRow = row == rows - 1 ? n - row * cols : cols;
      final rowW = inRow * tileW + (inRow - 1) * gap;
      final x0 = (gridW - rowW) / 2;
      slots.add(Offset(x0 + col * (tileW + gap), row * (tileH + gap)));
    }
    return _GridLayout(Size(tileW, tileH), slots, gridW, gridH);
  }
}
