import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../models/ai_service.dart';
import '../../platform/app_dock.dart';
import '../common/service_icon.dart';
import 'loading_splash.dart';

/// Kurulu Mac uygulamasının (ya da [webUrl] verilirse sahibin Chrome'undaki uygulama penceresinin)
/// oturduğu alan. Yerleşince saydam kalır (pencere saydam olduğu için alttaki pencere görünür).
class DockPane extends StatefulWidget {
  const DockPane({super.key, required this.service, required this.active, this.onUseWeb, this.webUrl, this.onClosed});

  final AiService service;

  /// Web kartı: Chrome `--app` penceresiyle açılır (oturum sahibin Chrome'unda).
  final String? webUrl;

  /// Chrome penceresini sahip kendisi kapattı: sekme kapanmalı.
  final VoidCallback? onClosed;

  /// Görüntüleyici tamamen açık ve bu kart seçili.
  final bool active;

  /// Kartı web sürümüne çevir (izin yoksa / uygulama kurulu değilse).
  final VoidCallback? onUseWeb;

  @override
  State<DockPane> createState() => _DockPaneState();
}

class _DockPaneState extends State<DockPane> {
  /// Canlı paneller: sekme değişince eski panel kapanırken yenisi çoktan kurulmuştur.
  static final _live = <_DockPaneState>{};

  final _dock = AppDock.instance;
  DockState _state = DockState.idle;
  String? _message;
  StreamSubscription<DockEvent>? _sub;
  Timer? _permissionPoll;
  Rect? _lastRect;
  int _attempt = 0;

  /// Sürükleme / canlı boyutlanma: delik marka zeminiyle örtülü (yerli taraf `coverOn`/`coverOff`).
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    _live.add(this);
    _sub = _dock.events.listen(_onEvent);
    if (widget.active) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(DockPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      widget.active ? _start() : _stop();
    }
  }

  @override
  void dispose() {
    _attempt++;
    _sub?.cancel();
    _permissionPoll?.cancel();
    _live.remove(this);
    // Başka bir kart yerleşmek üzereyse eski uygulama onun yerleşmesine kadar görünür kalır.
    if (_state == DockState.docked || _state == DockState.launching) {
      _dock.hide(keep: _live.any((p) => p.widget.active));
    }
    super.dispose();
  }

  void _onEvent(DockEvent e) {
    // Aynı uygulamanın başka kartı (ikinci hesap) ayrı süreçtir: olaylar kart kimliğiyle ayrılır.
    final other = e.key != null
        ? e.key != widget.service.id
        : e.bundleId != null && e.bundleId != _bundle;
    if (!mounted || other) return;
    switch (e.type) {
      case 'docked':
        setState(() => _state = DockState.docked);
      case 'coverOn' || 'coverOff':
        setState(() => _covered = e.type == 'coverOn');
      case 'terminated':
        _set(DockState.failed, t('viewer.terminated', {'name': widget.service.name}));
        if (widget.webUrl != null) widget.onClosed?.call();
      case 'windowLost':
        _set(DockState.failed, t('viewer.windowLost', {'name': widget.service.name}));
      case 'fullscreenUnsupported':
        _set(DockState.failed, t('viewer.fullscreenUnsupported'));
      case 'error':
        _set(DockState.failed, e.localizedMessage ?? t('viewer.dockFailed'));
    }
  }

  void _set(DockState s, [String? message]) {
    if (!mounted) return;
    setState(() {
      _state = s;
      _message = message;
      _covered = false;
    });
  }

  String? get _bundle => widget.webUrl != null ? AppDock.chromeBundleId : widget.service.macBundleId;

  Future<void> _start() async {
    final attempt = ++_attempt;
    _permissionPoll?.cancel();
    final bundle = _bundle;
    final web = widget.webUrl;
    if (!_dock.isSupported || bundle == null) {
      _set(DockState.failed, t('viewer.macOnly'));
      return;
    }
    _set(DockState.launching);
    // Her beklemeden sonra: kart pasifleştiyse ya da kapandıysa yerleştirme gönderilmez.
    bool stale() => !mounted || attempt != _attempt || !widget.active;
    final installed = await _dock.isInstalled(bundle);
    if (stale()) return;
    if (!installed) return _set(DockState.notInstalled);
    final trusted = await _dock.isTrusted();
    if (stale()) return;
    if (!trusted) {
      _set(DockState.needsPermission);
      _permissionPoll = Timer.periodic(const Duration(milliseconds: 1500), (t) async {
        if (await _dock.isTrusted()) {
          t.cancel();
          if (mounted && widget.active) _start();
        }
      });
      return;
    }
    final rect = mounted ? _rect() : null;
    if (rect == null) return;
    _lastRect = rect;
    final result = web != null
        ? await _dock.dockWeb(widget.service.id, web, rect)
        : await _dock.dock(widget.service.id, bundle, rect, separateProfile: widget.service.separateProfile);
    if (stale()) return;
    // Yerli taraf nedenini 'error' olayıyla bildirdiyse o ileti kalır.
    _set(result, result == DockState.failed ? _message ?? t('viewer.windowNotFound', {'name': widget.service.name}) : null);
    if (result == DockState.docked && !kReleaseMode) _dock.debugInstanceTest(widget.service.id, bundle, rect, webUrl: web);
  }

  void _stop() {
    _attempt++;
    _permissionPoll?.cancel();
    if (_state == DockState.docked || _state == DockState.launching) _dock.hide();
    _set(DockState.idle);
  }

  Rect? _rect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    if (_state == DockState.docked) {
      // Pencere boyutu ya da düzen değişirse yerli tarafa yeni alanı bildir.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final r = mounted ? _rect() : null;
        if (r != null && r != _lastRect) {
          _lastRect = r;
          _dock.updateRect(r);
        }
      });
      // Hedef pencerenin köşeleri yuvarlak: delik de yuvarlak olsun ki köşelerden masaüstü görünmesin.
      // Örtü, büyüyen kartın son karesiyle aynı görünüm (LoadingSplash'in zemini + simgesi).
      return CustomPaint(
        painter: const _HolePainter(),
        child: _covered
            ? ClipRRect(
                borderRadius: BorderRadius.circular(_HolePainter.radius),
                child: ServiceBackdrop(
                  service: widget.service,
                  child: Center(child: ServiceIcon(widget.service, size: LoadingSplash.iconSize)),
                ),
              )
            : const SizedBox.expand(),
      );
    }
    final s = widget.service;
    return AnimatedSwitcher(
      duration: Motion.medium,
      child: KeyedSubtree(
        key: ValueKey(_state),
        child: switch (_state) {
          DockState.idle || DockState.launching || DockState.docked =>
            LoadingSplash(service: s, label: t('viewer.docking', {'name': s.name})),
          DockState.needsPermission => LoadingSplash(
              service: s,
              label: t('viewer.needPermission', {'name': s.name}),
              child: _actions([
                _Action(t('viewer.openPermission'), Icons.lock_open_rounded, primary: true, onTap: () async {
                  await _dock.isTrusted(prompt: true);
                  await _dock.openAccessibilitySettings();
                }),
                if (s.canWeb && widget.onUseWeb != null)
                  _Action(t('viewer.useWeb'), Icons.language_rounded, onTap: widget.onUseWeb!),
              ], note: t('viewer.permissionPath')),
            ),
          DockState.notInstalled => LoadingSplash(
              service: s,
              label: widget.webUrl != null ? t('viewer.chromeMissing') : t('viewer.notInstalled', {'name': s.name}),
              child: _actions([
                if (s.canWeb && widget.onUseWeb != null)
                  _Action(t('viewer.useWeb'), Icons.language_rounded, primary: true, onTap: widget.onUseWeb!),
              ]),
            ),
          DockState.failed => LoadingSplash(
              service: s,
              label: _message ?? t('viewer.dockFailed'),
              child: _actions([
                _Action(t('viewer.reopen'), Icons.refresh_rounded, primary: true, onTap: _start),
                if (s.canWeb && widget.onUseWeb != null)
                  _Action(t('viewer.useWeb'), Icons.language_rounded, onTap: widget.onUseWeb!),
              ]),
            ),
        },
      ),
    );
  }

  Widget _actions(List<_Action> actions, {String? note}) {
    return Column(
      children: [
        Wrap(
          spacing: 10,
          children: [
            for (final a in actions)
              a.primary
                  ? FilledButton.icon(
                      onPressed: a.onTap,
                      icon: Icon(a.icon, size: 16),
                      label: Text(a.label),
                      style: FilledButton.styleFrom(backgroundColor: widget.service.color),
                    )
                  : OutlinedButton.icon(
                      onPressed: a.onTap,
                      icon: Icon(a.icon, size: 16),
                      label: Text(a.label),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        side: const BorderSide(color: AppColors.strokeHi),
                      ),
                    ),
          ],
        ),
        if (note != null) ...[
          const SizedBox(height: 12),
          Text(note, style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
        ],
      ],
    );
  }
}

class _Action {
  const _Action(this.label, this.icon, {required this.onTap, this.primary = false});

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
}

/// Alanı zeminle boyar, ortada yuvarlak köşeli saydam delik bırakır.
class _HolePainter extends CustomPainter {
  const _HolePainter();

  static const radius = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final all = Offset.zero & size;
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(all)
      ..addRRect(RRect.fromRectAndRadius(all, const Radius.circular(radius)));
    canvas.drawPath(path, Paint()..color = AppColors.bgElevated);
  }

  @override
  bool shouldRepaint(_HolePainter oldDelegate) => false;
}
