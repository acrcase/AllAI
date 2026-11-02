import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/widgets/ambient_clock.dart';
import '../../core/widgets/sprites.dart';
import '../../models/ai_service.dart';
import '../common/service_icon.dart';
import '../../l10n/l10n.dart';

/// Izgaradaki hover odağı: üzerine gelinen kartın kimliği ve merkezi (ızgara koordinatı).
@immutable
class TileFocus {
  const TileFocus(this.id, this.center);

  final String id;
  final Offset center;
}

/// Ana ekrandaki tek yapay zekâ kartı. Dokunma/sürükleme ızgarada; burada görünüm ve hover fiziği.
///
/// Performans: fare hareketi ağacı kurmaz; tek ticker yalnız bir şey hareket ederken çalışır ve
/// dönüşümü + iki boyacıyı yeniler. Yazı ve simge ayrı RepaintBoundary'de, yeniden çizilmez.
/// Gövde gradyanı bir kez görüntüye çizilir; ışıltılar hazır sprite, gölgeler analitik bulanık.
class AiTile extends StatefulWidget {
  const AiTile({
    super.key,
    required this.service,
    required this.size,
    this.center = Offset.zero,
    this.focus,
    this.dragDelta,
    this.editing = false,
    this.lifted = false,
    this.pressed = false,
    this.pressAt,
    this.dimmed = false,
    this.hideIcon = false,
    this.rehearse = false,
    this.lowestRemaining,
    this.jigglePhase = 0,
    this.onHoverChanged,
    this.onRemove,
    this.onToggleMode,
  });

  /// Tasarım kutusu: içerik bu ölçüde dizilir, kart boyuyla orantılı ölçeklenir.
  static const design = Size(212, 236);
  static const _iconCenter = Offset(106, 76);
  static const _iconSize = 82.0;

  /// Simgenin kart içindeki yeri (açılış uçuşu ve büyüme animasyonu buraya iner).
  static Rect iconRect(Size tile) {
    final k = tile.width / design.width;
    return Rect.fromCenter(center: _iconCenter * k, width: _iconSize * k, height: _iconSize * k);
  }

  /// Simge merkezinin hizası: kart açılışta simgenin etrafında büyür.
  static Alignment get iconAlignment => Alignment(0, _iconCenter.dy / design.height * 2 - 1);

  final AiService service;
  final Size size;

  /// Bu kartın ve [focus]'taki kartın merkezi aynı (ızgara) koordinatta: komşu itme için.
  final Offset center;
  final ValueListenable<TileFocus?>? focus;

  /// Sürüklenirken son fare adımı: kart hız yönüne hafifçe yatar.
  final ValueListenable<Offset>? dragDelta;
  final bool editing;

  /// Sürükleniyor: havaya kalkmış görünür.
  final bool lifted;
  final bool pressed;

  /// Basılan nokta (kart koordinatı): ışık dalgası buradan yayılır.
  final Offset? pressAt;

  /// Başka bir kart sürüklenirken geri planda kalır.
  final bool dimmed;

  /// Açılışta uçan simge henüz inmedi.
  final bool hideIcon;

  /// Açılışın siyah ekranında bir kez hover pozu (eğilme, kenar ışığı, kıvılcımlar, simge): ilk gerçek
  /// hover'da Skia gölgelendirici derlemesi (ölçüm: 18–40 ms'lik kare) olmasın. Kart o sırada görünmez.
  final bool rehearse;

  /// Kullanım panelindeki en düşük kalan oran (küçük halka).
  final double? lowestRemaining;
  final double jigglePhase;
  final ValueChanged<bool>? onHoverChanged;
  final VoidCallback? onRemove;
  final VoidCallback? onToggleMode;

  @override
  State<AiTile> createState() => _AiTileState();
}

class _AiTileState extends State<AiTile> with SingleTickerProviderStateMixin {
  static const _radius = 26.0;

  late final Ticker _ticker = createTicker(_tick);
  final _frame = Pulse();
  final _clock = AmbientClock.instance;
  Duration _last = Duration.zero;
  double time = 0; // ticker saati: kenar ışığı, kıvılcım

  bool _hover = false;
  Offset _ptr = Offset.zero; // -1..1
  Offset _ptrLocal = const Offset(0.5, 0.4); // 0..1

  // Yumuşatılmış durum.
  double hover = 0, press = 0, lift = 0, focusDim = 0, dim = 0, edit = 0;
  Offset tilt = Offset.zero, push = Offset.zero, dragTilt = Offset.zero, spot = const Offset(0.5, 0.4);
  Offset _dragTiltTarget = Offset.zero;
  double? rippleT;
  Offset rippleAt = Offset.zero;
  double? sweepT;
  double _iconShownAt = -100;

  // Kartın durağan görünümü (gölge, zemin ışığı, gövde, kenar, simge ışıması) iki önbellek
  // görüntüsünde: dinlenme ve hover. Eşzamansız üretilir; hazır olana dek canlı çizilir.
  // Önbellek durağan (boyut + renk anahtarlı): kart yeniden kurulunca (ana ekrana dönüş) beklemeden
  // çizilir, yeniden üretim ve o sıradaki canlı bulanık çizim olmaz.
  // Renk + dpr başına yalnız son boyut tutulur; pencere boyutlanırken eldeki görüntü ölçeklenerek çizilir,
  // yeni boyut boyutlanma 150 ms durulunca üretilir (her ara boyut için toImage yok).
  static final _cards = <String, (Size, ui.Image, ui.Image, Rect)>{};
  static final _cardPending = <String>{};
  static final _cardTimers = <String, Timer>{};
  static final _cardsBaked = ValueNotifier<int>(0);
  ui.Image? cardRest, cardHover;
  Rect cardRect = Rect.zero;


  @override
  void initState() {
    super.initState();
    widget.focus?.addListener(_wake);
    widget.dragDelta?.addListener(_onDrag);
    _clock.attach();
    if (widget.rehearse) sweepT = 0;
    if (widget.editing || widget.rehearse) _wake();
  }

  @override
  void didUpdateWidget(AiTile old) {
    super.didUpdateWidget(old);
    if (old.focus != widget.focus) {
      old.focus?.removeListener(_wake);
      widget.focus?.addListener(_wake);
    }
    if (old.dragDelta != widget.dragDelta) {
      old.dragDelta?.removeListener(_onDrag);
      widget.dragDelta?.addListener(_onDrag);
    }
    if (widget.pressed && !old.pressed && widget.pressAt != null) {
      rippleT = 0;
      rippleAt = widget.pressAt!;
    }
    if (old.hideIcon && !widget.hideIcon) _iconShownAt = _clock.seconds;
    if (widget.rehearse && !old.rehearse) sweepT = 0;
    if (old.rehearse != widget.rehearse ||
        old.pressed != widget.pressed ||
        old.lifted != widget.lifted ||
        old.dimmed != widget.dimmed ||
        old.editing != widget.editing ||
        old.center != widget.center) {
      _wake();
    }
  }

  @override
  void dispose() {
    widget.focus?.removeListener(_wake);
    widget.dragDelta?.removeListener(_onDrag);
    _clock.detach();
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _wake() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _onDrag() {
    if (!widget.lifted) return;
    final d = widget.dragDelta!.value;
    _dragTiltTarget = Offset((d.dy * 0.012).clamp(-0.12, 0.12), (-d.dx * 0.012).clamp(-0.12, 0.12));
    _wake();
  }

  void _setHover(bool v) {
    if (_hover == v) return;
    _hover = v;
    if (v) sweepT = 0;
    if (!v) _ptr = Offset.zero;
    widget.onHoverChanged?.call(v);
    _wake();
  }

  void _onMove(Offset local) {
    final s = widget.size;
    _ptrLocal = Offset((local.dx / s.width).clamp(0, 1), (local.dy / s.height).clamp(0, 1));
    _ptr = Offset(_ptrLocal.dx * 2 - 1, _ptrLocal.dy * 2 - 1);
    _wake();
  }

  void _tick(Duration e) {
    final dt = _last == Duration.zero ? 1 / 60 : ((e - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = e;
    time += dt;
    double ez(double k) => 1 - math.exp(-k * dt);
    double to(double v, double target, double k) => v + (target - v) * ez(k);

    final hoverT = (_hover || widget.rehearse) && !widget.lifted ? 1.0 : 0.0;
    hover = to(hover, hoverT, Motion.hoverK);
    press = to(press, widget.pressed ? 1 : 0, Motion.pressK);
    lift = to(lift, widget.lifted ? 1 : 0, Motion.hoverK);
    dim = to(dim, widget.dimmed ? 1 : 0, Motion.hoverK);
    edit = to(edit, widget.editing ? 1 : 0, Motion.hoverK);
    tilt = Offset.lerp(tilt, hoverT > 0 ? (_hover ? _ptr : const Offset(0.6, -0.5)) : Offset.zero, ez(Motion.tiltK))!;
    spot = Offset.lerp(spot, _ptrLocal, ez(Motion.tiltK))!;

    // Komşu itme: üzerine gelinen kartın çevresindekiler hafifçe uzaklaşır ve geri çekilir.
    final f = widget.focus?.value;
    var pushT = Offset.zero;
    var dimT = 0.0;
    if (f != null && f.id != widget.service.id && !widget.lifted) {
      final v = widget.center - f.center;
      final d = v.distance;
      if (d > 0) {
        final reach = widget.size.width * 1.7;
        pushT = v / d * Motion.neighborPush * math.exp(-(d / reach) * (d / reach));
      }
      dimT = 1;
    }
    push = Offset.lerp(push, pushT, ez(Motion.neighborK))!;
    focusDim = to(focusDim, dimT, Motion.neighborK);

    _dragTiltTarget *= math.exp(-7 * dt);
    dragTilt = Offset.lerp(dragTilt, widget.lifted ? _dragTiltTarget : Offset.zero, ez(Motion.tiltK))!;

    if (rippleT != null) {
      rippleT = rippleT! + dt / Motion.ripple;
      if (rippleT! >= 1) rippleT = null;
    }
    if (sweepT != null) {
      sweepT = sweepT! + dt / Motion.sweep;
      if (sweepT! >= 1) sweepT = null;
    }

    _frame.ping();

    final settled = !_hover &&
        !widget.rehearse &&
        !widget.editing &&
        hover < 0.002 &&
        (press - (widget.pressed ? 1 : 0)).abs() < 0.002 &&
        (lift - (widget.lifted ? 1 : 0)).abs() < 0.002 &&
        (dim - (widget.dimmed ? 1 : 0)).abs() < 0.002 &&
        edit < 0.002 &&
        (push - pushT).distance < 0.02 &&
        (focusDim - dimT).abs() < 0.002 &&
        tilt.distance < 0.002 &&
        dragTilt.distance < 0.001 &&
        rippleT == null &&
        sweepT == null;
    if (settled) {
      hover = 0;
      push = pushT;
      focusDim = dimT;
      _ticker.stop();
    }
  }

  /// Dönüşüm: boşta birim (katman açılmaz); 3B perspektif yalnız eğilen (hover/sürüklenen) kartta.
  /// Komşular düz 2B kayar ve çok hafif yana yatar.
  Matrix4 _matrix() {
    final up = math.max(hover, lift);
    final scale = 1 + Motion.hoverScale * hover + 0.07 * lift - Motion.pressScale * press - 0.012 * focusDim;
    final magnet = tilt * Motion.magnet * hover;
    final rx = -tilt.dy * Motion.tilt * hover + dragTilt.dx;
    final ry = tilt.dx * Motion.tilt * hover + dragTilt.dy;
    final rz = edit * (1 - lift) * math.sin((time / 0.56 + widget.jigglePhase) * 2 * math.pi) * 0.0175 + push.dx * 0.0016;
    final m = Matrix4.identity();
    final tilted = rx.abs() > 1e-4 || ry.abs() > 1e-4;
    if (tilted) m.setEntry(3, 2, 0.0011);
    m.translateByDouble(magnet.dx + push.dx, magnet.dy + push.dy - Motion.hoverLift * up, 0, 1);
    if (tilted) {
      m
        ..rotateX(rx)
        ..rotateY(ry);
    }
    if (rz.abs() > 1e-5) m.rotateZ(rz);
    if ((scale - 1).abs() > 1e-5) m.scaleByDouble(scale, scale, 1, 1);
    return m;
  }

  /// Önbellek varsa true (boyut farklıysa görüntü ölçeklenir); gerekiyorsa üretimi planlar.
  bool cardReady(Size size, double dpr) {
    if (Sprites.safe) return false; // Impeller: canlı çizim (bkz. Sprites.safe)
    final svc = widget.service;
    final key = '$dpr#${svc.color.toARGB32()}${svc.accent.toARGB32()}';
    final hit = _cards[key];
    if (hit == null || hit.$1 != size) {
      if (!_cardPending.contains(key)) {
        _cardTimers[key]?.cancel();
        _cardTimers[key] = Timer(hit == null ? Duration.zero : const Duration(milliseconds: 150), () => _bakeCard(key, size, dpr));
      }
    }
    if (hit == null) return false;
    final kx = size.width / hit.$1.width, ky = size.height / hit.$1.height;
    final r = hit.$4;
    cardRest = hit.$2;
    cardHover = hit.$3;
    cardRect = Rect.fromLTRB(r.left * kx, r.top * ky, r.right * kx, r.bottom * ky);
    return true;
  }

  static Future<void> _bakeCardFor(String key, Size size, double dpr, void Function(Canvas c, Size size, double hv) draw) async {
    _cardPending.add(key);
    final k = size.width / AiTile.design.width;
    final box = Rect.fromLTRB(-40 * k, -28 * k, size.width + 40 * k, size.height + 76 * k);
    Future<ui.Image> bake(double hv) {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec)
        ..scale(dpr)
        ..translate(-box.left, -box.top);
      draw(c, size, hv);
      final pic = rec.endRecording();
      return pic.toImage((box.width * dpr).ceil(), (box.height * dpr).ceil()).whenComplete(pic.dispose);
    }

    final rest = await bake(0), hover = await bake(1);
    _cardPending.remove(key);
    // Çizilmiş resimler görüntüyü kendileri tutar; eskisi hemen bırakılabilir.
    final old = _cards[key];
    _cards[key] = (size, rest, hover, box);
    old?.$2.dispose();
    old?.$3.dispose();
    _cardsBaked.value++;
  }

  void _bakeCard(String key, Size size, double dpr) {
    if (!mounted || _cardPending.contains(key)) return;
    _bakeCardFor(key, size, dpr, drawCard);
  }

  /// Kartın durağan görünümü: zemine düşen renkli ışık, gölge, (hover'da) marka ışıması, cam gövde,
  /// kenar, simge ışıması. [hv] 0 dinlenme, 1 hover; arası yumuşak geçiş.
  void drawCard(Canvas c, Size size, double hv) {
    final s = widget.service;
    final k = size.width / AiTile.design.width;
    final r = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(r, Radius.circular(_radius * k));
    // Zemine düşen renkli ışık (kartın altında, yansıma gibi).
    Sprites.paint(
      c,
      Sprites.glow,
      Rect.fromCenter(center: Offset(size.width / 2, size.height + 6 * k), width: size.width * (1.05 + 0.2 * hv), height: 76 * k),
      s.color.withValues(alpha: 0.18 + 0.36 * hv),
    );
    c.drawRRect(
      rr.shift(Offset(0, (10 + 12 * hv) * k)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30 + 0.16 * hv)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 14 * k),
    );
    if (hv > 0.01) {
      c.drawRRect(
        rr.deflate(10 * k).shift(Offset(0, 16 * k)),
        Paint()
          ..color = s.color.withValues(alpha: 0.42 * hv)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 22 * k),
      );
    }
    if (Sprites.safe) {
      // Impeller'da gradyan dolgu pahalı (8 kart ≈ 18 ms/kat): düz ton + üstte yumuşak parlaklık.
      c.drawRRect(rr, Paint()..color = Color.lerp(const Color(0x12FFFFFF), s.color.withValues(alpha: 0.24), 0.22 + 0.62 * hv)!);
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, size.height * 0.42), Radius.circular(_radius * k)),
        Paint()..color = Colors.white.withValues(alpha: 0.035 + 0.02 * hv),
      );
      c.drawRRect(
        rr.deflate(1.25),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.06 + 0.05 * hv),
      );
    } else {
      c.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(const Color(0x16FFFFFF), s.color.withValues(alpha: 0.30), 0.22 + 0.62 * hv)!,
              Color.lerp(const Color(0x07FFFFFF), s.accent.withValues(alpha: 0.10), hv)!,
            ],
          ).createShader(r),
      );
      // Üstten düşen cam parlaklığı.
      c.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [Colors.white.withValues(alpha: 0.07 + 0.04 * hv), Colors.white.withValues(alpha: 0)],
          ).createShader(r),
      );
      // İnce iç kabartma: üst kenar ışığı alır.
      c.drawRRect(
        rr.deflate(1.25),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.16 + 0.10 * hv),
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.03),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(r),
      );
    }
    c.drawRRect(
      rr.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Color.lerp(AppColors.stroke, s.accent.withValues(alpha: 0.55), hv)!,
    );
    // Simgenin arkasındaki marka ışıması.
    final icon = AiTile.iconRect(size);
    c.drawCircle(
      icon.center,
      icon.width * 0.36,
      Paint()
        ..color = s.color.withValues(alpha: 0.20 + 0.38 * hv)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, icon.width * 0.22),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    final size = widget.size;
    final k = size.width / AiTile.design.width;
    final iconRect = AiTile.iconRect(size);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final content = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: CustomPaint(painter: _BackPainter(this, dpr))),
        Positioned.fromRect(rect: iconRect, child: widget.hideIcon ? const SizedBox() : _icon(iconRect.width)),
        Positioned.fill(child: RepaintBoundary(child: _labels(s))),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _FrontPainter(this)))),
        if (widget.editing && widget.onRemove != null)
          Positioned(left: -8 * k, top: -8 * k, child: _RemoveBadge(onTap: widget.onRemove!)),
      ],
    );
    return MouseRegion(
      cursor: widget.lifted ? SystemMouseCursors.grabbing : SystemMouseCursors.click,
      onEnter: (e) {
        _onMove(e.localPosition);
        _setHover(true);
      },
      onExit: (_) => _setHover(false),
      onHover: (e) => _onMove(e.localPosition),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _frame,
          builder: (context, child) => Transform(alignment: Alignment.center, transform: _matrix(), child: child),
          child: SizedBox.fromSize(size: size, child: content),
        ),
      ),
    );
  }

  /// Simge: boşta farklı fazlarla nefes alır, hover'da yükselir ve imlece doğru kayar (paralaks).
  Widget _icon(double side) {
    final phase = (widget.service.id.hashCode % 1000) / 1000 * 2 * math.pi;
    return AnimatedBuilder(
      animation: Listenable.merge([_frame, _clock]),
      builder: (context, child) {
        final since = _clock.seconds - _iconShownAt;
        final ramp = Curves.easeInOut.transform((since / 1.4).clamp(0.0, 1.0)); // uçuştan inince yavaşça başlar
        final t = _clock.seconds * 2 * math.pi / Motion.breathePeriod + phase;
        final k = side / AiTile._iconSize;
        final breathe = Offset(math.cos(t * 0.5) * 0.35, math.sin(t)) * Motion.breatheAmp * k * ramp * (1 - hover);
        final par = tilt * 6 * k * hover;
        final sc = 1 + 0.07 * hover + 0.012 * ramp * math.sin(t) * (1 - hover);
        return Transform.translate(
          offset: breathe + par + Offset(0, -5 * k * hover),
          child: Transform.scale(scale: sc, child: child),
        );
      },
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: CustomPaint(painter: _IconGlowPainter(this))),
          RepaintBoundary(child: ServiceIcon(widget.service, size: side)),
        ],
      ),
    );
  }

  Widget _labels(AiService s) {
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox.fromSize(
        size: AiTile.design,
        child: Stack(
          children: [
            Positioned(
              left: 14,
              right: 14,
              top: 132,
              child: Text(
                s.name,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.text, letterSpacing: -0.2),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              top: 157,
              child: Text(
                s.displaySubtitle,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: AppColors.textDim),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 186,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ModeChip(service: s, editing: widget.editing, onTap: s.canApp && s.canWeb ? widget.onToggleMode : null),
                  if (widget.lowestRemaining != null) ...[
                    const SizedBox(width: 8),
                    _UsageDot(remaining: widget.lowestRemaining!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kartın önbellekteki görünümü (dinlenme ↔ hover geçişi) + yalnız hover'da canlı katmanlar:
/// kıvılcımlar, dönen konik kenar ışığı, imleç ışığı, ışık süpürmesi, basma dalgası.
class _BackPainter extends CustomPainter {
  _BackPainter(this.s, this.dpr) : super(repaint: Listenable.merge([s._frame, Sprites.ready, _AiTileState._cardsBaked]));

  final _AiTileState s;
  final double dpr;

  @override
  void paint(Canvas c, Size size) {
    final svc = s.widget.service;
    final k = size.width / AiTile.design.width;
    final h = s.hover, up = math.max(s.hover, s.lift);
    final r = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(r, Radius.circular(_AiTileState._radius * k));

    if (s.cardReady(size, dpr)) {
      final rest = s.cardRest!, hov = s.cardHover!;
      final src = Rect.fromLTWH(0, 0, rest.width.toDouble(), rest.height.toDouble());
      if (up < 0.998) {
        c.drawImageRect(rest, src, s.cardRect,
            Paint()
              ..filterQuality = FilterQuality.low
              ..color = Color.fromRGBO(255, 255, 255, 1 - up));
      }
      if (up > 0.002) {
        c.drawImageRect(hov, src, s.cardRect,
            Paint()
              ..filterQuality = FilterQuality.low
              ..color = Color.fromRGBO(255, 255, 255, up));
      }
    } else {
      s.drawCard(c, size, up);
    }

    if (h > 0.01) {
      _sparks(c, size, k, h);
      _border(c, rr, r, k, h);
    }

    final ripple = s.rippleT, sweep = s.sweepT;
    if (h > 0.01 || ripple != null || sweep != null) {
      c.save();
      c.clipRRect(rr);
      if (h > 0.01) {
        final p = Offset(s.spot.dx * size.width, s.spot.dy * size.height);
        Sprites.paint(c, Sprites.glow, Rect.fromCenter(center: p, width: size.width * 1.5, height: size.width * 1.5),
            Colors.white.withValues(alpha: 0.11 * h));
        Sprites.paint(c, Sprites.glow, Rect.fromCenter(center: p, width: size.width * 2.4, height: size.width * 2.4),
            svc.accent.withValues(alpha: 0.10 * h));
      }
      if (sweep != null) {
        final t = Curves.easeInOutCubic.transform(sweep);
        final x = (t * 2 - 1) * size.width * 1.3 + size.width / 2;
        Sprites.paint(c, Sprites.band, Rect.fromCenter(center: Offset(x, size.height / 2), width: size.width * 0.5, height: size.height * 2.2),
            Colors.white.withValues(alpha: 0.13 * math.sin(sweep * math.pi)),
            rotation: math.pi / 7);
      }
      if (ripple != null) {
        final e = Curves.easeOutCubic.transform(ripple);
        final rad = (size.longestSide * 1.25) * e + 6;
        Sprites.paint(c, Sprites.ring, Rect.fromCircle(center: s.rippleAt, radius: rad),
            Color.lerp(Colors.white, svc.accent, 0.4)!.withValues(alpha: 0.5 * math.pow(1 - ripple, 1.4)));
        Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: s.rippleAt, radius: 60 * k + rad * 0.5),
            Colors.white.withValues(alpha: 0.18 * (1 - ripple)));
      }
      c.restore();
    }
  }

  /// Dönen konik gradyan: kenarda dolaşan ışık + yumuşak hale.
  void _border(Canvas c, RRect rr, Rect r, double k, double h) {
    final svc = s.widget.service;
    final a = s.time * 2 * math.pi / Motion.borderSpin;
    final shader = SweepGradient(
      colors: [
        svc.color.withValues(alpha: 0),
        svc.color.withValues(alpha: 0),
        svc.color,
        svc.accent,
        Colors.white,
        svc.accent.withValues(alpha: 0),
        svc.accent.withValues(alpha: 0),
        svc.color.withValues(alpha: 0.6),
        svc.color.withValues(alpha: 0),
      ],
      stops: const [0, 0.30, 0.42, 0.50, 0.53, 0.60, 0.80, 0.90, 1],
      transform: GradientRotation(a),
    ).createShader(r);
    c.drawRRect(
      rr.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * k
        ..shader = shader
        ..color = Color.fromRGBO(255, 255, 255, h),
    );
    // Hale: bulanıklık yerine iki geniş, sönük çizgi (dönüşümlü katmanda bulanıklık pahalı).
    for (final (w, a) in const [(4.5, 0.30), (9.0, 0.12)]) {
      c.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * k
          ..shader = shader
          ..color = Color.fromRGBO(255, 255, 255, a * h),
      );
    }
  }

  /// Kartın arkasından yükselen marka renkli kıvılcımlar (yazının arkasında kalır, okunurluğu bozmaz).
  void _sparks(Canvas c, Size size, double k, double h) {
    final svc = s.widget.service;
    const n = 14;
    for (var i = 0; i < n; i++) {
      double rnd(int j) => (math.sin((i + 1) * 12.9898 + j * 78.233) * 43758.5453) % 1.0;
      final period = 1.5 + 1.1 * rnd(1).abs();
      final life = ((s.time + rnd(2).abs() * period) % period) / period;
      final x = size.width * (0.1 + 0.8 * rnd(3).abs()) + math.sin(life * math.pi * 2 + rnd(4) * 6) * 7 * k;
      final y = size.height * (1.0 - life * 1.18);
      final alpha = math.sin(math.pi * life) * h * (y < 0 ? (1 + y / (30 * k)).clamp(0.0, 1.0) : 1);
      final px = (1.4 + 1.6 * rnd(5).abs()) * k * 4;
      Sprites.paint(
        c,
        Sprites.dot,
        Rect.fromCircle(center: Offset(x, y), radius: px / 2),
        (i.isEven ? svc.accent : Color.lerp(svc.accent, Colors.white, 0.5)!).withValues(alpha: (0.85 * alpha).clamp(0.0, 1.0)),
        blend: BlendMode.plus,
      );
    }
  }

  @override
  bool shouldRepaint(_BackPainter old) => old.s != s || old.dpr != dpr;
}

/// Sürükleme sırasında arka plandaki kartları ve hover'daki kartın komşularını karartır
/// (saydamlık katmanı yerine üst örtü: kart başına saveLayer açılmaz).
class _FrontPainter extends CustomPainter {
  _FrontPainter(this.s) : super(repaint: s._frame);

  final _AiTileState s;

  @override
  void paint(Canvas c, Size size) {
    final a = 0.42 * s.dim + 0.10 * s.focusDim * (1 - s.dim);
    if (a < 0.004) return;
    final k = size.width / AiTile.design.width;
    c.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(_AiTileState._radius * k)),
      Paint()..color = AppColors.bg.withValues(alpha: a),
    );
  }

  @override
  bool shouldRepaint(_FrontPainter old) => old.s != s;
}

/// Simgenin arkasındaki marka renkli ışıma.
/// Hover'da simgenin arkasında güçlenen ışıma (durağan ışıma önbellek görüntüsünde).
class _IconGlowPainter extends CustomPainter {
  _IconGlowPainter(this.s) : super(repaint: s._frame);

  final _AiTileState s;

  @override
  void paint(Canvas c, Size size) {
    if (s.hover < 0.01) return;
    Sprites.paint(c, Sprites.glow, Rect.fromCenter(center: size.center(Offset.zero), width: size.width * 2.2, height: size.width * 2.2),
        s.widget.service.color.withValues(alpha: 0.45 * s.hover),
        blend: BlendMode.plus);
  }

  @override
  bool shouldRepaint(_IconGlowPainter old) => old.s != s;
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.service, required this.editing, this.onTap});

  final AiService service;
  final bool editing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final app = service.mode == OpenMode.app;
    final window = service.canLaunch; // Windows programı: kendi penceresinde açılır
    final toggle = editing && onTap != null;
    final chip = AnimatedContainer(
      duration: Motion.medium,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        color: toggle ? service.color.withValues(alpha: 0.28) : const Color(0x1AFFFFFF),
        border: Border.all(color: toggle ? service.accent.withValues(alpha: 0.7) : const Color(0x0FFFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(window ? Icons.open_in_new_rounded : app ? Icons.laptop_mac_rounded : Icons.language_rounded, size: 12, color: AppColors.textDim),
          const SizedBox(width: 5),
          Text(
            window ? t('home.chip_window') : app ? t('home.chip_app') : t('home.chip_web'),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textDim),
          ),
          if (toggle) ...[
            const SizedBox(width: 4),
            const Icon(Icons.swap_horiz_rounded, size: 12, color: AppColors.text),
          ],
        ],
      ),
    );
    if (!toggle) return chip;
    return Tooltip(
      message: app ? t('home.switch_web') : t('home.switch_app'),
      child: GestureDetector(onTap: onTap, child: chip),
    );
  }
}

class _UsageDot extends StatelessWidget {
  const _UsageDot({required this.remaining});

  final double remaining;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.forRemaining(remaining);
    return Tooltip(
      message: t('home.tip_lowest', {'n': (remaining * 100).round()}),
      child: SizedBox.square(
        dimension: 18,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: remaining.clamp(0, 1),
              strokeWidth: 2.6,
              color: c,
              backgroundColor: const Color(0x22FFFFFF),
              strokeCap: StrokeCap.round,
            ),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoveBadge extends StatefulWidget {
  const _RemoveBadge({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_RemoveBadge> createState() => _RemoveBadgeState();
}

class _RemoveBadgeState extends State<_RemoveBadge> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.15 : 1,
          duration: Motion.fast,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? AppColors.bad : const Color(0xFF2A2D3A),
              border: Border.all(color: AppColors.strokeHi),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8)],
            ),
            child: const Icon(Icons.close_rounded, size: 15, color: AppColors.text),
          ),
        ),
      ),
    );
  }
}
