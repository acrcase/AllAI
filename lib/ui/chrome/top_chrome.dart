import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/widgets/ambient_clock.dart';
import '../../core/widgets/cosmic_mark.dart';
import '../../core/widgets/sprites.dart';
import '../../data/services_store.dart';
import '../../models/ai_service.dart';
import '../../l10n/l10n.dart';
import '../home/add_service_sheet.dart';
import 'edit_extras.dart';
import '../viewer/viewer_layer.dart';

/// Kısayol ipucundaki değiştirici tuş (kısayollar root_screen.dart'ta: macOS ⌘, öteki Ctrl).
final _mod = Platform.isMacOS ? '⌘' : 'Ctrl+';

/// Başlık ve köşe öğeleri kartlardan sonra süzülerek gelir (açılış).
Widget revealIn(bool revealed, double delay, Widget child) {
  return AnimatedOpacity(
    opacity: revealed ? 1 : 0,
    duration: Duration(milliseconds: 600 + (delay * 600).round()),
    curve: Interval(delay * 0.5, 1, curve: Curves.easeOut),
    child: AnimatedSlide(
      offset: revealed ? Offset.zero : const Offset(0, -0.15),
      duration: Duration(milliseconds: 700 + (delay * 600).round()),
      curve: Interval(delay * 0.5, 1, curve: Motion.decelerate),
      child: child,
    ),
  );
}

/// Ana ekran ile görüntüleyicinin ORTAK üst çubuğu. Logo ve zemin hep yerinde kalır; [progress]
/// (0 ana ekran, 1 görüntüleyici) ilerledikçe selamlama sola, logonun arkasına kayıp gider ve yerine
/// "Ana ekran" + açık yapay zekâ gelir; Ekle/Düzenle sağa kayıp gider, yerine açık yapay zekânın
/// limit/geri/ileri/yenile/biçim düğmeleri gelir. Sekme şeridi iki hâlde de ortada.
class TopChrome extends StatelessWidget {
  const TopChrome({
    super.key,
    required this.progress,
    required this.revealed,
    required this.services,
    required this.openTabs,
    required this.active,
    required this.editing,
    required this.webView,
    required this.onHome,
    required this.onTapTab,
    required this.onCloseTab,
    required this.onTabGone,
    required this.onAdd,
    required this.onReload,
    required this.onBack,
    required this.onForward,
    this.drag,
  });

  /// Yan öğelere en az bu kadar yer kalır; şerit sığmazsa yatay kayar.
  static const _side = 380.0;

  final Animation<double> progress;
  final bool revealed;
  final List<AiService> services;
  final ValueListenable<OpenTabs> openTabs;

  /// Görüntüleyicide etkin kart (ana ekrandayken null).
  final AiService? active;
  final ValueNotifier<bool> editing;
  final ValueListenable<bool> webView;
  final VoidCallback onHome;
  final ValueChanged<AiService> onTapTab;
  final ValueChanged<String> onCloseTab;
  final ValueChanged<String> onTabGone;

  /// "+": açık olmayan kartlar [rest].
  final Future<void> Function(BuildContext anchor, List<AiService> rest) onAdd;
  final VoidCallback onReload;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final Widget Function(Widget child)? drag;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: ViewerLayerState.barHeight,
      child: revealIn(
        revealed,
        0,
        Stack(
          children: [
            // Görüntüleyicide çubuğun altına ince çizgi.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedBuilder(
                animation: progress,
                builder: (context, _) => Opacity(
                  opacity: progress.value.clamp(0.0, 1.0),
                  child: const SizedBox(
                    height: 1,
                    child: ColoredBox(color: AppColors.stroke),
                  ),
                ),
              ),
            ),
            // Sürükleme katmanı arkada: düğmeler kendi dokunuşlarını alır, boş alan pencereyi taşır.
            if (drag != null)
              Positioned.fill(child: drag!(const SizedBox.expand())),
            LayoutBuilder(
              builder: (context, c) => Padding(
                padding: const EdgeInsets.only(top: ViewerLayerState.barTop),
                child: AnimatedBuilder(
                  animation: progress,
                  builder: (context, _) =>
                      _row(context, progress.value.clamp(0.0, 1.0), c.maxWidth),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, double p, double width) {
    final a = active;
    return Row(
      children: [
        Expanded(
          child: Padding(
            // macOS: sol üstteki trafik ışıkları için boşluk; Windows'ta yerel başlık çubuğu ayrı.
            padding: EdgeInsets.only(left: Platform.isMacOS ? 92 : 28),
            child: Row(
              children: [
                const IgnorePointer(child: AppLogo()),
                // Kırpma logonun hemen sağında başlar: öğeler logonun arkasından çıkıp arkasına girer.
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: !editing.value || p > 0.05,
                            child: Opacity(
                              opacity: 1 - p,
                              child: FractionalTranslation(
                                translation: Offset(-p, 0),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 18),
                                    child: GreetingLine(editing: editing),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: p < 0.95,
                            child: Opacity(
                              opacity: p,
                              child: FractionalTranslation(
                                translation: Offset(p - 1, 0),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: LayoutBuilder(
                                      builder: (context, c) => Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Dar yerde yalnız simge; çok dar yerde ad da gizlenir.
                                          BarButton(
                                            icon: Icons.grid_view_rounded,
                                            label: c.maxWidth < 150
                                                ? null
                                                : t('core.home'),
                                            tooltip: '${t('core.home')} (${_mod}0)',
                                            onTap: onHome,
                                          ),
                                          if (a != null &&
                                              c.maxWidth >= 260) ...[
                                            const SizedBox(width: 10),
                                            Flexible(child: ActiveLabel(a)),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ValueListenableBuilder<OpenTabs>(
          valueListenable: openTabs,
          builder: (context, open, _) =>
              _strip(context, open, math.max(0.0, width - 2 * _side)),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 28),
            child: Stack(
              alignment: Alignment.centerRight,
              children: [
                IgnorePointer(
                  ignoring: p > 0.05,
                  child: Opacity(
                    opacity: 1 - p,
                    child: FractionalTranslation(
                      translation: Offset(p * 1.4, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: editing,
                            builder: (context, on, _) => ListenableBuilder(
                              listenable: L10n.instance,
                              builder: (context, _) => EditExtras(
                                editing: on,
                                language: HeaderButton(
                                  icon: Icons.language_rounded,
                                  label: L10n.languages.firstWhere((l) => l.code == L10n.instance.code).name,
                                  onTap: () => showLanguageDialog(context),
                                ),
                                reset: DangerButton(
                                  icon: Icons.restart_alt_rounded,
                                  label: t('core.reset'),
                                  onTap: () => showResetDialog(context),
                                ),
                              ),
                            ),
                          ),
                          HeaderButton(
                            icon: Icons.add_rounded,
                            label: t('core.add'),
                            onTap: () => showAddServiceSheet(context),
                          ),
                          const SizedBox(width: 10),
                          ValueListenableBuilder<bool>(
                            valueListenable: editing,
                            builder: (context, on, _) => HeaderButton(
                              icon: on
                                  ? Icons.check_rounded
                                  : Icons.tune_rounded,
                              label: on ? t('core.done') : t('core.edit'),
                              active: on,
                              onTap: () => editing.value = !on,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (a != null)
                  IgnorePointer(
                    ignoring: p < 0.95,
                    child: Opacity(
                      opacity: p,
                      child: FractionalTranslation(
                        translation: Offset((1 - p) * 1.4, 0),
                        child: _viewerActions(a),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _viewerActions(AiService a) {
    return ValueListenableBuilder<bool>(
      valueListenable: webView,
      builder: (context, inApp, _) {
        final web = a.mode == OpenMode.web && inApp;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UsageMini(service: a),
            if (web) ...[
              BarButton(
                icon: Icons.arrow_back_rounded,
                tooltip: '${t('core.back')} ($_mod[)',
                onTap: onBack,
              ),
              BarButton(
                icon: Icons.arrow_forward_rounded,
                tooltip: '${t('core.forward')} ($_mod])',
                onTap: onForward,
              ),
              BarButton(
                icon: Icons.refresh_rounded,
                tooltip: '${t('core.reload')} (${_mod}R)',
                onTap: onReload,
              ),
            ],
            if (a.canApp && a.canWeb)
              BarButton(
                icon: a.mode == OpenMode.app
                    ? Icons.language_rounded
                    : Icons.laptop_mac_rounded,
                tooltip: a.mode == OpenMode.app
                    ? t('core.to_web')
                    : t('core.to_app'),
                onTap: () => ServicesStore.instance.setMode(
                  a.id,
                  a.mode == OpenMode.app ? OpenMode.web : OpenMode.app,
                ),
              ),
          ],
        );
      },
    );
  }

  /// Açık yapay zekâlar: tıklayınca ona geçilir, × kapatır, "+" açık olmayanlardan birini açar.
  Widget _strip(BuildContext context, OpenTabs open, double maxWidth) {
    final byId = {for (final s in services) s.id: s};
    final tabs = [for (final id in open.strip) ?byId[id]];
    if (tabs.isEmpty) return const SizedBox.shrink();
    final rest = [
      for (final s in services)
        if (!open.strip.contains(s.id) || open.closing.contains(s.id)) s,
    ];
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // Uçlarda boşluk: seçili sekmenin ışıltısı kesilmesin.
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: TabStrip(
          tabs: tabs,
          services: services,
          selectedId: active?.id ?? open.last,
          closing: open.closing,
          onTap: onTapTab,
          onClose: onCloseTab,
          onGone: onTabGone,
          onAdd: rest.isEmpty ? null : (anchor) => onAdd(anchor, rest),
        ),
      ),
    );
  }
}

/// Başlıkta canlı logo: kozmik işaret (halkasında yavaşça dolaşan ışık) + aralıklarla üzerinden ışık
/// geçen "AllAI".
class AppLogo extends StatefulWidget {
  const AppLogo({super.key});

  @override
  State<AppLogo> createState() => _LogoState();
}

class _LogoState extends State<AppLogo> {
  final _clock = AmbientClock.instance;

  @override
  void initState() {
    super.initState();
    _clock.attach();
  }

  @override
  void dispose() {
    _clock.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: const Size(124, 36),
        painter: _LogoPainter(_clock),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.clock)
    : super(repaint: Listenable.merge([clock, Sprites.ready]));

  final AmbientClock clock;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.seconds;
    // İşaret: halka ~42 px genişlikte (gövde kenarı 56 px), küre ~19 px.
    CosmicMark.paint(canvas, Offset(21, size.height / 2), 56, t: t);

    // Yazı: beyazdan gümüşe; her 7 sn'de bir soldan sağa ışık süpürmesi.
    const x0 = 48.0;
    final phase = (t % 7.0) / 1.3; // 0..1 süpürme, sonra bekleme
    final band = phase < 1 ? Curves.easeInOutCubic.transform(phase) : -1.0;
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: 'AllAI',
        style: TextStyle(
          fontSize: 27,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.9,
          height: 1,
          foreground: Paint()
            ..shader = LinearGradient(
              colors: band < 0
                  ? const [Color(0xFFFFFFFF), Color(0xFFB4BBC7)]
                  : const [
                      Color(0xFFFFFFFF),
                      Color(0xFFB4BBC7),
                      Color(0xFFFFFFFF),
                      Color(0xFFB4BBC7),
                    ],
              stops: band < 0
                  ? null
                  : [
                      0,
                      (band - 0.12).clamp(0.0, 1.0),
                      band.clamp(0.0, 1.0),
                      (band + 0.12).clamp(0.0, 1.0),
                    ],
            ).createShader(Rect.fromLTWH(x0, 0, 72, size.height)),
        ),
      ),
    )..layout();
    // Yazının arkasında hafif ışık (hazır sprite; her karede gölge bulanıklığı yok).
    Sprites.paint(
      canvas,
      Sprites.glow,
      Rect.fromCenter(
        center: Offset(x0 + tp.width / 2, size.height / 2),
        width: tp.width * 1.5,
        height: size.height * 1.3,
      ),
      const Color(0xFFFFFFFF).withValues(alpha: 0.10),
    );
    tp.paint(canvas, Offset(x0, (size.height - tp.height) / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(_LogoPainter old) => false;
}

class HeaderButton extends StatefulWidget {
  const HeaderButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  State<HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<HeaderButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          transform: Matrix4.translationValues(0, _hover ? -1.5 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            color: widget.active
                ? AppColors.text
                : (_hover ? AppColors.surfaceHi : AppColors.surface),
            border: Border.all(
              color: _hover || widget.active
                  ? AppColors.strokeHi
                  : AppColors.stroke,
            ),
            boxShadow: _hover
                ? const [
                    BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 12,
                      offset: Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 16,
                color: widget.active ? AppColors.bg : AppColors.text,
              ),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: widget.active ? AppColors.bg : AppColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
