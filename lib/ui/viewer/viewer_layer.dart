
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../data/services_store.dart';
import '../../l10n/l10n.dart';
import '../../models/ai_service.dart';
import '../../platform/app_dock.dart';
import '../../usage/usage_models.dart';
import '../../usage/usage_repository.dart';
import '../common/service_icon.dart';
import 'dock_pane.dart';
import 'web_pane.dart';

/// Görüntüleyicinin sekme şeridi dışarıdan görüldüğü hâliyle: sıra (kapananlar dahil), kapanmakta
/// olanlar, en son kullanılan.
typedef OpenTabs = ({List<String> strip, Set<String> closing, String? last});

/// Açılmış yapay zekâlar: üst çubuk (ortada açık sekmeler) + içerik.
/// Açılan her yapay zekâ × ile kapatılana kadar canlı kalır; ana ekrana dönmek kapatmaz.
class ViewerLayer extends StatefulWidget {
  const ViewerLayer({
    super.key,
    required this.active,
    required this.visible,
    required this.services,
    required this.onHome,
    required this.onSwitch,
    this.webView,
    this.openTabs,
  });

  final AiService? active;

  /// Büyüme animasyonu bitti, içerik görünür.
  final bool visible;
  final List<AiService> services;
  final VoidCallback onHome;
  final ValueChanged<AiService> onSwitch;

  /// Web kartları yerleşik görünümde mi (geri/ileri/yenile yalnız onda); üst çubuk bunu okur.
  final ValueNotifier<bool>? webView;

  /// Açık sekmeler (şerit sırasıyla) dışarıya yayınlanır: ana ekranın üst çubuğu gösterir.
  final ValueNotifier<OpenTabs>? openTabs;

  @override
  State<ViewerLayer> createState() => ViewerLayerState();
}

class ViewerLayerState extends State<ViewerLayer> {
  /// Ana ekranın başlığıyla aynı yükseklik; sekme şeridi o başlıktaki gibi 22 px aşağıda durur.
  static const barHeight = 76.0;
  static const barTop = 22.0;

  /// Şerit, düğmeler ve boşluklar bu yükseklikte (başlık satırı = barHeight - barTop).
  static const rowHeight = 52.0;

  /// Şeritteki sırayla sekmeler (kapanırken küçülenler dahil).
  final _strip = <String>[];

  /// Kapanma animasyonu oynayan sekmeler; içerikleri çoktan kapandı.
  final _closing = <String>{};

  /// Açık sekmeler, en son kullanılan sonda.
  final _recent = <String>[];

  /// Sekmenin açıldığı biçim: kart web ↔ uygulama arasında değişirse eski içerik kapanır.
  final _modes = <String, OpenMode>{};
  final _keys = <String, GlobalKey<WebPaneState>>{};
  final _contentKey = GlobalKey();

  /// Açık (kapanmakta olmayan) sekmeler, şerit sırasıyla.
  List<String> get openIds => [
    for (final id in _strip)
      if (!_closing.contains(id)) id,
  ];

  /// "+" menüsü açıkken AllAI odağı kaybederse (yerleşik uygulamaya, masaüstüne ya da başka
  /// uygulamaya tıklandı) menü kapanır; o tıklamalar Flutter'a hiç ulaşmaz.
  late final _lifecycle = AppLifecycleListener(
    onInactive: _closeAddMenu,
    onHide: _closeAddMenu,
  );
  bool _menuOpen = false;

  /// macOS'ta Chrome kurulu ve Erişilebilirlik izni varsa web kartları sahibin Chrome'unda uygulama
  /// penceresiyle açılıp deliğe yerleşir (oturum Chrome'un); değilse yerleşik web görünümü (izinsiz de
  /// çalışır). Oturum boyunca sabit; bilinene kadar (null) içerik çizilmez.
  bool? _chrome;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _activate();
    _decideChrome();
  }

  Future<void> _decideChrome() async {
    final dock = AppDock.instance;
    final chrome = await dock.webInChrome() && await dock.isTrusted();
    if (mounted) setState(() => _chrome = chrome);
    widget.webView?.value = !chrome;
  }

  /// İçerik yerli pencere olarak deliğe yerleşir (uygulama ya da Chrome penceresi).
  bool _docked(AiService? s) =>
      s != null &&
      (s.mode == OpenMode.app || (s.mode == OpenMode.web && _chrome == true));

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _closeAddMenu() {
    if (_menuOpen && mounted) Navigator.of(context).popUntil((r) => r is! PopupRoute);
  }

  @override
  void didUpdateWidget(ViewerLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
    if (widget.active?.id != oldWidget.active?.id) _activate();
  }

  /// Etkin kart sekme olur (zaten açıksa yalnız en son kullanılan olur).
  void _activate() {
    final a = widget.active;
    if (a == null) return;
    _closing.remove(a.id);
    if (!_strip.contains(a.id)) _strip.add(a.id);
    _modes[a.id] = a.mode;
    _recent
      ..remove(a.id)
      ..add(a.id);
  }

  /// Kart listesi değişti: kaldırılan kartın sekmesi kapanır, biçimi değişen sekmenin eski içeriği bırakılır.
  void _sync() {
    final byId = {for (final s in widget.services) s.id: s};
    for (final id in [..._strip]) {
      final s = byId[id];
      final open = !_closing.contains(id);
      if (s == null) {
        if (open) _release(id);
        _strip.remove(id);
        _closing.remove(id);
        _recent.remove(id);
      } else if (open && s.mode != _modes[id]) {
        _release(id);
        _modes[id] = s.mode;
      }
    }
  }

  /// Sekmenin içeriğini kapatır: web görünümü atılır (oturum çerezleri kalır), uygulama kapatılır.
  void _release(String id) {
    switch (_modes.remove(id)) {
      case OpenMode.app:
        AppDock.instance.close(id);
      case OpenMode.web:
        if (_chrome == true) AppDock.instance.close(id);
        _keys.remove(id);
      case null:
        break;
    }
  }

  /// Sekmenin ×'i: içerik hemen kapanır, simge küçülerek şeritten çıkar. Etkin sekme kapandıysa
  /// en son kullanılan açık sekmeye geçilir; hiç kalmadıysa ana ekrana dönülür.
  void close(String id) {
    if (!_strip.contains(id) || _closing.contains(id)) return;
    setState(() {
      _release(id);
      _closing.add(id);
      _recent.remove(id);
    });
    if (widget.active?.id != id) return;
    final byId = {for (final s in widget.services) s.id: s};
    final next = _recent.reversed.map((e) => byId[e]).nonNulls.firstOrNull;
    if (next == null) {
      widget.onHome();
    } else {
      widget.onSwitch(next);
    }
  }

  void gone(String id) {
    if (!_closing.contains(id)) return;
    setState(() {
      _closing.remove(id);
      _strip.remove(id);
    });
  }

  WebPaneState? get _pane =>
      widget.active == null ? null : _keys[widget.active!.id]?.currentState;

  void reload() => _pane?.reload();
  void back() => _pane?.back();
  void forward() => _pane?.forward();

  Rect? _contentRect() {
    final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// "+": açık olmayan kartlar; seçilen açılır.
  Future<void> showAddMenu(BuildContext anchor) async {
    final open = openIds.toSet();
    final list = [
      for (final s in widget.services)
        if (!open.contains(s.id)) s,
    ];
    if (list.isEmpty) return;
    // Menü yerleşik uygulamanın deliğinin üstüne açılır: o sürede tıklamalar uygulamaya geçmesin.
    final docked = _docked(widget.active);
    if (docked) AppDock.instance.updateRect(Rect.zero);
    _menuOpen = true;
    final chosen = await showServiceMenu(context, anchor, list);
    _menuOpen = false;
    if (!mounted) return;
    if (chosen != null) {
      widget.onSwitch(chosen);
    } else if (docked && _docked(widget.active)) {
      final c = _contentRect();
      if (c != null) AppDock.instance.updateRect(c);
    }
  }

  /// Kare bitince yayınlanır: dinleyiciler kurulum sırasında yeniden kurulmasın.
  void _publish() {
    final out = widget.openTabs;
    if (out == null) return;
    final OpenTabs now = (
      strip: [..._strip],
      closing: {..._closing},
      last: _recent.lastOrNull,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final old = out.value;
      if (!mounted ||
          listEquals(old.strip, now.strip) &&
              setEquals(old.closing, now.closing) &&
              old.last == now.last) {
        return;
      }
      out.value = now;
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.active;
    final byId = {for (final s in widget.services) s.id: s};
    final open = openIds;
    _publish();
    // Üst çubuk RootScreen'deki TopChrome'dur (ana ekranla ortak); burada yalnız yeri ayrılır.
    return Column(
      children: [
        const SizedBox(height: barHeight),
        Expanded(
          child: Stack(
            key: _contentKey,
            children: [
              for (final id in open)
                if (byId[id] case final s?
                    when s.mode == OpenMode.web && _chrome == false)
                  Positioned.fill(
                    key: ValueKey('web-$id'),
                    child: Offstage(
                      offstage: !(widget.visible && a?.id == id),
                      child: TickerMode(
                        enabled: a?.id == id,
                        child: WebPane(
                          key: _keys.putIfAbsent(
                            id,
                            GlobalKey<WebPaneState>.new,
                          ),
                          service: s,
                        ),
                      ),
                    ),
                  ),
              if (a != null && _docked(a) && open.contains(a.id))
                Positioned.fill(
                  child: a.mode == OpenMode.web
                      ? DockPane(
                          key: ValueKey('chrome-${a.id}'),
                          service: a,
                          active: widget.visible,
                          webUrl: a.webUrl,
                          onClosed: () => close(a.id),
                        )
                      : DockPane(
                          key: ValueKey('dock-${a.id}'),
                          service: a,
                          active: widget.visible,
                          onUseWeb: a.canWeb
                              ? () => ServicesStore.instance.setMode(
                                  a.id,
                                  OpenMode.web,
                                )
                              : null,
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "+" menüsü: verilen kartlar, seçilen döner.
Future<AiService?> showServiceMenu(
  BuildContext context,
  BuildContext anchor,
  List<AiService> list,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final box = anchor.findRenderObject()! as RenderBox;
  final r = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final id = await showMenu<String>(
    context: context,
    color: AppColors.bgElevated,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: AppColors.stroke),
    ),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(r.left, r.bottom - 6, r.width, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final s in list)
        PopupMenuItem(
          key: ValueKey('add-${s.id}'),
          value: s.id,
          height: 40,
          child: Row(
            children: [
              ServiceIcon(s, size: 22),
              const SizedBox(width: 10),
              Text(
                s.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  s.subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
  return list.where((s) => s.id == id).firstOrNull;
}

/// Açık sekmeler + "+": görüntüleyicinin üst çubuğunda ve ana ekranın başlığında aynı.
class TabStrip extends StatelessWidget {
  const TabStrip({
    super.key,
    required this.tabs,
    required this.services,
    required this.selectedId,
    required this.closing,
    required this.onTap,
    required this.onClose,
    required this.onGone,
    this.onAdd,
    this.animateIn = true,
  });

  final List<AiService> tabs;

  /// Bütün kartlar: aynı adlı kartları ayırmak için.
  final List<AiService> services;
  final String? selectedId;
  final Set<String> closing;
  final ValueChanged<AiService> onTap;
  final ValueChanged<String> onClose;
  final ValueChanged<String> onGone;

  /// Verilmezse "+" yok (açılmamış kart kalmadı).
  final Future<void> Function(BuildContext)? onAdd;

  /// false: şerit yeniden kurulunca (ana ekrana dönüş) sekmeler büyüyerek gelmez, yerinde durur.
  final bool animateIn;

  /// Aynı adlı kartlar alt başlıkla ayrılır: "Claude (Hesap 2)".
  String _label(AiService s) =>
      services.where((o) => o.name == s.name).length > 1
      ? '${s.name} (${s.subtitle})'
      : s.name;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in tabs)
          _Tab(
            key: ValueKey('tab-${s.id}'),
            service: s,
            label: _label(s),
            selected: s.id == selectedId,
            closing: closing.contains(s.id),
            onTap: () => onTap(s),
            onClose: () => onClose(s.id),
            onGone: () => onGone(s.id),
            animateIn: animateIn,
          ),
        if (onAdd case final add?)
          _AddButton(key: const ValueKey('tab-add'), onTap: add),
      ],
    );
  }
}

/// Etkin yapay zekânın simgesi, adı ve nerede açıldığı; dar pencerede kısalır.
class ActiveLabel extends StatelessWidget {
  const ActiveLabel(this.service, {super.key});

  final AiService service;

  @override
  Widget build(BuildContext context) {
    final s = service;
    final where = s.separateProfile
        ? s.subtitle
        : s.mode == OpenMode.app
        ? 'Uygulama'
        : (Uri.tryParse(s.webUrl ?? '')?.host ?? '');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ServiceIcon(s, size: 24, showBadge: false),
        const SizedBox(width: 8),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: s.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(
                  text: '  $where',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Açık yapay zekâ sekmesi: üzerine gelince hafif büyür, sağ üstte × belirir.
/// Açılınca büyüyerek gelir, kapanınca küçülerek gider. Hover ağacı yeniden kurmaz (yalnız dönüşüm ve saydamlık).
class _Tab extends StatefulWidget {
  const _Tab({
    super.key,
    required this.service,
    required this.label,
    required this.selected,
    required this.closing,
    required this.onTap,
    required this.onClose,
    required this.onGone,
    this.animateIn = true,
  });

  static const width = 46.0;
  static const box = 34.0;

  final AiService service;
  final String label;
  final bool selected;
  final bool closing;
  final VoidCallback onTap;
  final VoidCallback onClose;

  /// Küçülme bitti: şeritten çıkarılabilir.
  final VoidCallback onGone;
  final bool animateIn;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with TickerProviderStateMixin {
  late final AnimationController _life;
  late final AnimationController _hover;
  late final Animation<double> _grow;
  late final Animation<double> _dim;
  late final Animation<double> _fade;
  final _hovering = ValueNotifier(false);
  final _overClose = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _life =
        AnimationController(
          vsync: this,
          duration: Motion.medium,
          reverseDuration: const Duration(milliseconds: 200),
        )..addStatusListener((s) {
          if (s == AnimationStatus.dismissed && widget.closing) widget.onGone();
        });
    if (widget.animateIn && !widget.closing) {
      _life.forward();
    } else if (!widget.closing) {
      _life.value = 1;
    }
    _hover = AnimationController(vsync: this, duration: Motion.fast);
    final eased = CurvedAnimation(parent: _hover, curve: Curves.easeOut);
    _grow = Tween(begin: 1.0, end: 1.08).animate(eased);
    _dim = Tween(begin: 0.6, end: 1.0).animate(eased);
    _fade = eased;
  }

  @override
  void didUpdateWidget(_Tab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      widget.closing ? _life.reverse() : _life.forward();
    }
  }

  @override
  void dispose() {
    _life.dispose();
    _hover.dispose();
    _hovering.dispose();
    _overClose.dispose();
    super.dispose();
  }

  void _setHover(bool on) {
    _hovering.value = on;
    on ? _hover.forward() : _hover.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    final selected = widget.selected;
    final box = AnimatedContainer(
      duration: Motion.fast,
      width: _Tab.box,
      height: _Tab.box,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: selected ? s.color.withValues(alpha: 0.22) : Colors.transparent,
        border: Border.all(
          color: selected
              ? s.accent.withValues(alpha: 0.7)
              : Colors.transparent,
        ),
        boxShadow: selected
            ? [BoxShadow(color: s.color.withValues(alpha: 0.4), blurRadius: 12)]
            : null,
      ),
      child: ServiceIcon(s, size: 26),
    );
    return AnimatedBuilder(
      animation: _life,
      builder: (context, child) {
        final v = Motion.emphasized.transform(_life.value);
        return Align(
          widthFactor: v,
          child: Opacity(
            opacity: v,
            child: Transform.scale(scale: v, child: child),
          ),
        );
      },
      child: IgnorePointer(
        ignoring: widget.closing,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _setHover(true),
          onExit: (_) => _setHover(false),
          child: Tooltip(
            message: widget.label,
            child: GestureDetector(
              onTap: widget.onTap,
              child: ScaleTransition(
                scale: _grow,
                child: SizedBox(
                  width: _Tab.width,
                  height: ViewerLayerState.rowHeight,
                  child: Stack(
                    children: [
                      Center(
                        child: FadeTransition(
                          opacity: selected ? kAlwaysCompleteAnimation : _dim,
                          child: box,
                        ),
                      ),
                      // × kutunun sağ üst köşesinde; dokunma alanı görünenden geniş.
                      Positioned(
                        left: 28,
                        top: 3,
                        width: 18,
                        height: 18,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _hovering,
                          builder: (context, on, child) =>
                              IgnorePointer(ignoring: !on, child: child),
                          child: FadeTransition(
                            opacity: _fade,
                            child: _CloseDot(
                              key: ValueKey('tab-close-${s.id}'),
                              over: _overClose,
                              onTap: widget.onClose,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseDot extends StatelessWidget {
  const _CloseDot({super.key, required this.over, required this.onTap});

  final ValueNotifier<bool> over;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: t('viewer.close'),
      child: MouseRegion(
        onEnter: (_) => over.value = true,
        onExit: (_) => over.value = false,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: over,
              builder: (context, on, _) => Container(
                width: 15,
                height: 15,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? AppColors.bad : AppColors.bgElevated,
                  border: Border.all(
                    color: on ? AppColors.bad : AppColors.strokeHi,
                  ),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 10,
                  color: on ? AppColors.text : AppColors.textDim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Şeridin sonundaki "+": açık olmayan kartların menüsü.
class _AddButton extends StatefulWidget {
  const _AddButton({super.key, required this.onTap});

  final Future<void> Function(BuildContext) onTap;

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  final _hover = ValueNotifier(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: t('viewer.addAnother'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _hover.value = true,
        onExit: (_) => _hover.value = false,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Menü kapanınca vurgu söner: imleç deliğe geçtiyse çıkış olayı Flutter'a gelmez.
          onTap: () async {
            await widget.onTap(context);
            if (mounted) _hover.value = false;
          },
          child: SizedBox(
            width: _Tab.width,
            height: ViewerLayerState.rowHeight,
            child: Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: _hover,
                builder: (context, on, _) => AnimatedContainer(
                  duration: Motion.fast,
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: on ? AppColors.surfaceHi : Colors.transparent,
                    border: Border.all(
                      color: on ? AppColors.strokeHi : AppColors.stroke,
                    ),
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    size: 17,
                    color: on ? AppColors.text : AppColors.textFaint,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Açık yapay zekânın en kritik limiti; üzerine gelince ayrıntı.
class UsageMini extends StatelessWidget {
  const UsageMini({super.key, required this.service});

  final AiService service;

  @override
  Widget build(BuildContext context) {
    final repo = UsageRepository.instance;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final r = repo.reports[service.usageKey];
        if (r == null || r.status != UsageStatus.ok) return const SizedBox.shrink();
        final low = r.lowestRemaining;
        final meters = [for (final s in r.sections) ...s.meters];
        final lines = [
          if (r.plan != null) r.plan!,
          for (final m in meters.take(8))
            '${m.label}: ${m.unlimited
                ? t('viewer.unlimited')
                : m.remaining == null
                ? '?'
                : t('viewer.remainingPct', {'p': (m.remaining! * 100).round()})}',
          if (meters.length > 8) t('viewer.moreLimits', {'n': meters.length - 8}),
        ];
        final c = AppColors.forRemaining(low);
        return Tooltip(
          message: lines.join('\n'),
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              color: AppColors.surface,
              border: Border.all(color: AppColors.stroke),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    value: (low ?? 0).clamp(0, 1),
                    strokeWidth: 2.4,
                    color: c,
                    backgroundColor: const Color(0x22FFFFFF),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  low == null ? t('viewer.limit') : '%${(low * 100).round()}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class BarButton extends StatefulWidget {
  const BarButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.label,
    this.tooltip,
  });

  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  State<BarButton> createState() => BarButtonState();
}

class BarButtonState extends State<BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.fast,
          height: 32,
          padding: EdgeInsets.symmetric(
            horizontal: widget.label == null ? 8 : 12,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: _hover ? AppColors.surfaceHi : Colors.transparent,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 17,
                color: _hover ? AppColors.text : AppColors.textDim,
              ),
              if (widget.label != null) ...[
                const SizedBox(width: 7),
                Text(
                  widget.label!,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? child
        : Tooltip(message: widget.tooltip!, child: child);
  }
}
