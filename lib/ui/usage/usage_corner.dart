import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/widgets/glass.dart';
import 'usage_button.dart';
import '../../usage/usage_repository.dart';
import 'usage_panel.dart';
import 'usage_view_state.dart';

/// Ana ekranın sağ alt köşesi: "Kullanım limitleri" düğmesi ve açılır paneli.
///
/// SÖZLEŞME: ana ekran bunu `Positioned.fill` içine koyar; düğmeyi sağ alta kendisi yerleştirir,
/// paneli sağ alttan açar. Dışarı tıklayınca / Esc ile kapanır.
class UsageCorner extends StatefulWidget {
  const UsageCorner({super.key, this.serviceIcons = const {}});

  /// usageKey -> simge varlık yolu (panel başlıklarında uygulama simgesi göstermek için).
  final Map<String, String> serviceIcons;

  @override
  State<UsageCorner> createState() => _UsageCornerState();
}

class _UsageCornerState extends State<UsageCorner> with SingleTickerProviderStateMixin {
  static const _panelWidth = 520.0;
  static const _gap = 12.0;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: Motion.collapse,
    reverseDuration: Motion.medium,
  )..addStatusListener((_) => setState(() {}));

  // Açılış: yaylı büyüme. Kapanış: başta yavaş, köşeye doğru hızlanan küçülme.
  late final CurvedAnimation _scale = CurvedAnimation(
    parent: _ctrl,
    curve: Motion.springOut,
    reverseCurve: Motion.decelerate,
  );
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _ctrl,
    curve: const Interval(0, 0.6, curve: Motion.decelerate),
  );

  final _panelFocus = FocusNode(debugLabel: 'usage-panel');
  bool _open = false;

  // Panel kapanıp açılınca korunan görünüm durumu.
  // Diske de yazılır: uygulama yeniden açılınca da son bırakılan görünüm gelir.
  UsageViewState _view = UsageViewState();

  @override
  void initState() {
    super.initState();
    UsageViewState.load().then((v) {
      if (mounted) setState(() => _view = v);
    });
  }

  @override
  void dispose() {
    _scale.dispose();
    _fade.dispose();
    _ctrl.dispose();
    _panelFocus.dispose();
    super.dispose();
  }

  void _toggle() => _open ? _close() : _show();

  void _show() {
    setState(() => _open = true);
    // Panel kapalıyken bayatlayan veri açılırken tazelenir; taze olana dokunulmaz.
    UsageRepository.instance.refreshStale(maxAge: const Duration(minutes: 2));
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl.value = 1;
    } else {
      _ctrl.forward();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) _panelFocus.requestFocus();
    });
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _panelFocus.unfocus();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl.value = 0;
    } else {
      _ctrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      final safe = MediaQuery.paddingOf(context);
      final margin = size.width < 520 ? 16.0 : 24.0;
      final right = margin + safe.right;
      final bottom = margin + safe.bottom;
      final panelBottom = bottom + UsageButton.height + _gap;
      final panelWidth = math.min(_panelWidth, size.width - right - margin - safe.left);
      final maxHeight = math.max(
        0.0,
        math.min(size.height * 0.75, size.height - panelBottom - margin - safe.top),
      );
      final visible = !_ctrl.isDismissed;

      return PopScope(
        canPop: !_open,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: AppColors.text, decoration: TextDecoration.none),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (visible)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_open,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _close,
                      child: FadeTransition(
                        opacity: _fade,
                        child: ColoredBox(color: AppColors.bg.withValues(alpha: 0.32)),
                      ),
                    ),
                  ),
                ),
              if (visible)
                Positioned(
                  right: right,
                  bottom: panelBottom,
                  width: panelWidth,
                  child: IgnorePointer(
                    ignoring: !_open,
                    child: CallbackShortcuts(
                      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
                      child: Focus(
                        focusNode: _panelFocus,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: maxHeight),
                          child: _PanelChrome(
                            scale: _scale,
                            fade: _fade,
                            child: UsagePanel(
                              serviceIcons: widget.serviceIcons,
                              filter: _view.filter,
                              onFilter: (id) => setState(() {
                                _view
                                  ..filter = id
                                  ..scroll = 0
                                  ..save();
                              }),
                              collapsed: _view.collapsed,
                              onToggleCard: (id) => setState(() {
                                if (!_view.collapsed.remove(id)) _view.collapsed.add(id);
                                _view.save();
                              }),
                              scrollOffset: _view.scroll,
                              onScrolled: (y) {
                                _view.scroll = y;
                                _view.save();
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: right,
                bottom: bottom,
                child: UsageButton(open: _open, onTap: _toggle),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Cam gövde + açılış hareketi: sağ alt merkezli ölçek, saydamlık, bulanıktan netliğe.
///
/// Arka plan bulanıklığı panel başına tek BackdropFilter; saydamlık onu sarmaz (sarsa bulanıklık
/// bozulurdu), yalnız içeriği sarar. Durgunken Opacity ve ImageFiltered katman açmaz.
class _PanelChrome extends StatelessWidget {
  const _PanelChrome({required this.scale, required this.fade, required this.child});

  final Animation<double> scale;
  final Animation<double> fade;
  final Widget child;

  static const _radius = 22.0;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: scale,
    child: child,
    builder: (context, child) {
      final o = fade.value;
      final blur = (1 - o) * 10;
      return Transform.scale(
        scale: 0.6 + 0.4 * scale.value,
        alignment: Alignment.bottomRight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            boxShadow: [
              BoxShadow(
                color: AppColors.bg.withValues(alpha: 0.5 * o),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: GlassPanel(
            radius: _radius,
            tint: AppColors.bgElevated.withValues(alpha: 0.94 * o),
            border: AppColors.strokeHi.withValues(alpha: 0.24 * o),
            child: DecoratedBox(
              // Üst kenardan süzülen ince ışık: cam hissi.
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [
                    AppColors.surface.withValues(alpha: 0.07 * o),
                    AppColors.surface.withValues(alpha: 0),
                  ],
                ),
              ),
              child: Opacity(
                opacity: o,
                child: ImageFiltered(
                  enabled: blur > 0.05,
                  imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
