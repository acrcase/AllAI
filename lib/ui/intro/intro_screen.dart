import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion.dart';
import '../../core/widgets/cosmic_mark.dart';
import '../../core/widgets/shader_warmup.dart';
import '../../core/widgets/sprites.dart';
import '../../models/ai_service.dart';
import '../common/service_icon.dart';
import '../home/frame_probe.dart';
import 'intro_timing.dart';

typedef _G = CosmicGeometry;

/// Açılış (~3,2 sn; tıklama ya da herhangi bir tuş atlar):
/// sakin kozmik boşlukta (siyah, ince yıldızlar, uzakta silik galaksiler) ortada büyük, hacimli bir gezegen:
/// koyu iç gradyanlı küre, kalın parlak jant, ışınlı yıldız çekirdeği ve hale; birkaç bantlı kalın halka
/// (binlerce parçacık, ışık izleri, toz; arka yarısı kürenin arkasında, ön yarısı önünde), yörüngeler, aylar,
/// parıltılar → halka dönmeye başlar, giderek hızlanır (hız çizgileri), çekirdek hızlanan nabızla parlar,
/// titreşim, içine çekilme → PATLAMA: beyaz parlama, kamera "yumruğu" (kısa yakınlaşma), sarsıntı, kalın şok
/// dalgaları; halka kart sayısı kadar kalın ışıklı yaya kopar (tozunu da taşır), küre kırılır, enkaz saçılır →
/// her yay kavisli bir yolla kendi kartına uçar, çarptığında darbe halkası ve parlamayla o yapay zekânın
/// simgesine dönüşür; kart çevresinde açılır, ana ekran arkadan belirir.
///
/// Gezegen yordamsal ([CosmicGeometry], uygulama simgesinden ölçülü): halka gerçekten döner. Çizim tek
/// boyacıda: zemin ve küre gölgelemesi hazır görüntü (açılıştan önce GPU'ya yüklenir), çizgiler drawVertices,
/// parçacıklar ve hız çizgileri drawAtlas, ışıklar hazır sprite; kare başına bulanıklık ya da katman yok.
/// Simgeler gerçek [ServiceIcon]: inişte kartın simgesiyle aynı.
class IntroScreen extends StatefulWidget {
  const IntroScreen({
    super.key,
    required this.controller,
    required this.services,
    required this.targetOf,
    required this.onReveal,
    required this.onDone,
  });

  /// 0..1, süresi [Motion.intro]; ızgara da kartlarını bununla açar.
  final AnimationController controller;
  final List<AiService> services;

  /// Kartın simge yeri (ekran koordinatı); yay buraya iner.
  final Rect? Function(String id) targetOf;

  /// Yaylar kartlara uçmaya başladı: başlık ve köşe öğeleri gelsin.
  final VoidCallback onReveal;
  final VoidCallback onDone;

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  static final _debris = _Debris.make();

  ui.Image? _space;
  bool _loading = false;
  bool _revealed = false;
  bool _skipping = false;
  bool _precached = false;

  /// Kart simge yerleri. Çizim sırasında değil, ticker anında (önceki karenin yerleşimi tamken) okunur.
  final _targets = <String, Rect>{};
  _Plan? _plan;

  AnimationController get _c => widget.controller;

  /// Görsel denetim için: `ALLAI_INTRO_T=0.5` açılışı o anda dondurur (yalnız profil/hata ayıklama).
  static final double? _freeze =
      kReleaseMode ? null : double.tryParse(Platform.environment['ALLAI_INTRO_T'] ?? '');

  @override
  void initState() {
    super.initState();
    _c.addListener(_onTick);
    _c.addStatusListener(_onStatus);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    var icons = Future<void>.value();
    if (!_precached) {
      _precached = true;
      icons = Future.wait([
        for (final s in widget.services)
          if (s.icon != null) precacheImage(AssetImage(s.icon!), context),
      ]);
    }
    if (_loading) return;
    _loading = true;
    final art = Future.wait<void>([
      _loadSpace(MediaQuery.sizeOf(context), MediaQuery.devicePixelRatioOf(context)),
      _Art.init().then((_) {
        if (mounted) setState(() {});
      }),
    ]);
    if (_freeze != null) {
      art.whenComplete(() => WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _readTargets();
            _c.value = _freeze!.clamp(0.0, 1.0);
          }));
      return;
    }
    // Önce gölgelendiriciler ısınır, zemin, küre ve simgeler hazırlanır; iki kare daha beklenir ki ilk
    // çizimdeki doku yüklemeleri (kart provası, simgeler) siyah ekranda kalsın (ölçüm: 45–65 ms'lik ilk kareler).
    const wait = Duration(milliseconds: 900);
    Future.wait<void>([
      warmUpShaders().timeout(wait).catchError((Object _) {}),
      art.timeout(wait).catchError((Object _) => <void>[]),
      icons.timeout(wait).catchError((Object _) {}),
    ]).whenComplete(() async {
      for (var i = 0; i < 2 && mounted; i++) {
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || _c.isAnimating || _c.value != 0) return;
      FrameProbe.enter('acilis-oyun'); // ölçüm: ısınma (siyah ekran) ile görünen açılış ayrı
      _c.forward();
    });
  }

  /// Zemini pencere boyu × dpr'ye göre çözer (en çok doğal 2400 px) ve küçük bir resme çizerek dokuyu
  /// açılış başlamadan GPU'ya yükletir.
  Future<void> _loadSpace(Size size, double dpr) async {
    try {
      final need = (math.max(size.width, size.height * 1.6) * dpr).ceil();
      final data = await rootBundle.load('assets/brand/cosmic_space.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: need < 2400 ? need : null);
      final img = (await codec.getNextFrame()).image;
      codec.dispose();
      await _upload(img);
      if (!mounted) return img.dispose();
      setState(() => _space = img);
    } catch (_) {
      // Zemin yoksa açılış siyah boşlukta oynar.
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onTick);
    _c.removeStatusListener(_onStatus);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _space?.dispose();
    super.dispose();
  }

  void _readTargets() {
    for (final s in widget.services) {
      final r = widget.targetOf(s.id);
      if (r != null) _targets[s.id] = r;
    }
  }

  void _onTick() {
    if (_c.value <= IntroTiming.at(IntroTiming.landBy + 0.1)) _readTargets();
    if (!_revealed && _c.value >= IntroTiming.at(IntroTiming.flight0)) {
      _revealed = true;
      widget.onReveal();
    }
  }

  void _onStatus(AnimationStatus s) {
    // animateTo(ara değer) de "completed" bildirir (atlamada uçuşa sarma): yalnız sonda bitir.
    if (s == AnimationStatus.completed && _c.value >= 1 && _freeze == null) widget.onDone();
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) _skip();
    return true; // açılış sürerken kısayollar çalışmasın
  }

  /// İlk uçuşa kadar hızla sar, sonra uçuşları hızlandırılmış oynat (uçuş atlanmaz: ana ekrana köprü).
  void _skip() {
    final f0 = IntroTiming.at(IntroTiming.flight0);
    if (_skipping || _freeze != null || _c.value >= f0) return;
    _skipping = true;
    _c.animateTo(f0, duration: Motion.introSkip, curve: Curves.easeIn).then((_) {
      if (!mounted) return;
      _c.animateTo(1, duration: Motion.intro * ((1 - f0) / Motion.introSkipRate));
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: LayoutBuilder(
        builder: (context, box) => AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final lay = _Layout(box.biggest);
            // Yayların kartlara atanması bir kez, bütün hedefler bilinince (en geç patlamada) kurulur.
            if (_plan == null || _plan!.n != widget.services.length) {
              _plan = _Plan.tryMake(widget.services, _targets, lay, _debris,
                  force: _c.value >= IntroTiming.at(IntroTiming.burst));
            }
            final f = _Frame(lay, _c.value, widget.services, _targets, _plan, _debris, _space);
            return Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _IntroPainter(f)),
                for (final ic in f.icons) _icon(ic),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _icon(_IconPose ic) {
    final child = ServiceIcon(ic.service, size: ic.rect.width);
    return Positioned.fromRect(
      rect: ic.rect,
      child: Transform.scale(
        scale: ic.scale,
        child: ic.alpha >= 0.995 ? child : Opacity(opacity: ic.alpha.clamp(0.0, 1.0), child: child),
      ),
    );
  }
}

/// Küçük bir resme çizerek dokuyu GPU'ya yükletir (ilk kullanımda raster iş parçacığı beklemesin).
Future<void> _upload(ui.Image img) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), const Rect.fromLTWH(0, 0, 4, 4), Paint());
  final pic = rec.endRecording();
  (await pic.toImage(4, 4)).dispose();
  pic.dispose();
}

/// Açılışa özel hazır görüntüler (bir kez, eşzamansız): hacimli küre (koyu iç gradyan, jantın iç ışığı,
/// içte ince çember, hafif yansıma) ve hız çizgisi. Kare başına gradyan ya da bulanıklık yerine ölçeklenir.
abstract final class _Art {
  static ui.Image? sphere, streak;
  static Future<void>? _init;

  static Future<void> init() => _init ??= _make();

  static Future<ui.Image> _draw(int w, int h, void Function(Canvas c, Size s) body) async {
    final rec = ui.PictureRecorder();
    body(Canvas(rec), Size(w.toDouble(), h.toDouble()));
    final pic = rec.endRecording();
    final img = await pic.toImage(w, h);
    pic.dispose();
    await _upload(img);
    return img;
  }

  static Future<void> _make() async {
    sphere = await _draw(512, 512, (c, s) {
      final o = s.center(Offset.zero);
      final r = s.width / 2;
      c.save();
      c.clipPath(Path()..addOval(Rect.fromCircle(center: o, radius: r)));
      c.drawCircle(
        o,
        r,
        Paint()
          ..shader = const RadialGradient(
            colors: [Color(0xFF050508), Color(0xFF09090E), Color(0xFF181820), Color(0xFF5A5A66), Color(0xFFEDEDF2)],
            stops: [0, 0.68, 0.88, 0.962, 1],
          ).createShader(Rect.fromCircle(center: o, radius: r)),
      );
      final h = o.translate(-r * 0.28, -r * 0.32);
      c.drawCircle(h, r * 0.62, Paint()
        ..shader = const RadialGradient(colors: [Color(0x16FFFFFF), Color(0x00FFFFFF)]).createShader(Rect.fromCircle(center: h, radius: r * 0.62)));
      c.drawCircle(o, r * 0.86, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.010
        ..color = const Color(0x48FFFFFF));
      c.restore();
    });
    streak = await _draw(128, 16, (c, s) {
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(10, 5, 108, 6), const Radius.circular(3)),
          Paint()
            ..color = const Color(0xFFFFFFFF)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4));
    });
  }
}

double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

double _smooth(double a, double b, double x) {
  final t = _seg(x, a, b);
  return t * t * (3 - 2 * t);
}

Offset _unit(Offset v) {
  final l = v.distance;
  return l < 1e-6 ? const Offset(0, -1) : v / l;
}

double _ease(double x) => Curves.easeOutCubic.transform(x);

/// Yerleşim: gezegen ekranın ortasında; küre çapı pencere yüksekliğinin ~%56'sı (gövde ölçüsü 1,65 × yükseklik),
/// halka genişliği pencerenin en çok %88'i.
class _Layout {
  _Layout(this.size)
      : u = math.min(size.width / 1280, size.height / 820).clamp(0.6, 1.4).toDouble(),
        center = Offset(size.width / 2, size.height / 2 - 4),
        side = math.min(size.height * 1.65, size.width * 0.88 / (2 * _G.ringA * 1.04));

  final Size size;
  final double u;
  final Offset center;
  final double side;

  /// Gezegene göre piksel birimi: çizgi ve parçacık kalınlıkları gezegenle büyür.
  double get pu => side / 1000;

  /// Gezegen koordinatından (gövde birimi) ekrana, sarsıntısız; yıldız merkezde.
  Offset at(Offset g, [double scale = 1]) => center + (g - _G.star) * side * scale;
}

/// Patlama anındaki açısal hız (rad/s).
const _spinB = 0.55 + 7.0;

/// Halkanın açısal konumu (rad): dönüş yavaş başlar, patlamaya doğru karesel hızlanır; patlamadan sonra
/// parçalar dönüşü sönerek sürdürür.
double _ringAngle(double s) {
  const b = IntroTiming.burst;
  final x = math.min(s, b);
  final a = 0.55 * x + 7.0 * x * x * x / (3 * b * b);
  if (s <= b) return a;
  return a + _spinB * (1 - math.exp(-4 * (s - b))) / 4;
}

double _spinAt(double s) {
  const b = IntroTiming.burst;
  final x = math.min(s, b);
  return 0.55 + 7.0 * x * x / (b * b);
}

/// Halka yaylarının kartlara atanması: her yay, ekranda kendi kartının yönünde durur (uçuş yolları
/// kesişmez). Halka parçacıklarının her biri bir yaya bağlanır (yayın ortası) ya da kıvılcım olur (kenarlar).
class _Plan {
  _Plan(this.n, this.arcs, this.theta0, this.serviceOf, this.moteArc, this.moteOff);

  final int n;
  final int arcs;

  /// İlk yayın orta açısı (halkanın dönen çerçevesinde).
  final double theta0;
  final List<int> serviceOf;

  /// Parçacık → yay (-1: kıvılcım) ve yay ortasına göre açı.
  final List<int> moteArc;
  final List<double> moteOff;

  double get span => 2 * math.pi / arcs;
  double mid(int a) => theta0 + a * span;

  static double _angDiff(double a, double b) {
    var d = (a - b) % (2 * math.pi);
    if (d > math.pi) d -= 2 * math.pi;
    return d;
  }

  static _Plan? tryMake(List<AiService> services, Map<String, Rect> targets, _Layout lay, _Debris debris, {required bool force}) {
    final n = services.length;
    if (!services.every((s) => targets.containsKey(s.id)) && !force) return null;
    final arcs = n == 0 ? 6 : n;
    final d = 2 * math.pi / arcs;
    final spin = _ringAngle(IntroTiming.flight0);
    double ang(Offset p) => math.atan2(p.dy - lay.center.dy, p.dx - lay.center.dx);
    final known = [for (var i = 0; i < n; i++) if (targets[services[i].id] != null) i];
    final want = {for (final i in known) i: ang(targets[services[i].id]!.center)};
    known.sort((a, b) => want[a]!.compareTo(want[b]!));
    var best = double.infinity;
    var bestTheta = 0.0;
    var bestRot = 0;
    var bestOrder = List.generate(arcs, (a) => a);
    for (var k = 0; k < 24; k++) {
      final th0 = k / 24 * d;
      final arcAng = [for (var a = 0; a < arcs; a++) ang(lay.at(_G.ring(th0 + a * d + spin, 1.2)))];
      final order = List.generate(arcs, (a) => a)..sort((x, y) => arcAng[x].compareTo(arcAng[y]));
      for (var r = 0; r < arcs; r++) {
        var cost = 0.0;
        for (var m = 0; m < known.length; m++) {
          final diff = _angDiff(arcAng[order[(m + r) % arcs]], want[known[m]]!);
          cost += diff * diff;
        }
        if (cost < best) {
          best = cost;
          bestTheta = th0;
          bestRot = r;
          bestOrder = order;
        }
      }
    }
    final serviceOf = List.filled(arcs, -1);
    final taken = List.filled(n, false);
    for (var m = 0; m < known.length; m++) {
      serviceOf[bestOrder[(m + bestRot) % arcs]] = known[m];
      taken[known[m]] = true;
    }
    final free = [for (var a = 0; a < arcs; a++) if (serviceOf[a] < 0) a];
    for (var i = 0; i < n; i++) {
      if (!taken[i] && free.isNotEmpty) serviceOf[free.removeAt(0)] = i;
    }
    // Patlama anında her parçacığın yayı: yayın ortadaki %70'i yayla gider, kenarlar kıvılcım olur.
    final rotB = _ringAngle(IntroTiming.burst);
    final moteArc = <int>[], moteOff = <double>[];
    for (final m in debris.motes) {
      final rel = m.theta + rotB * m.speed - rotB - bestTheta;
      final x = (rel + d / 2) % (2 * math.pi);
      final a = (x / d).floor() % arcs;
      final off = x - a * d - d / 2;
      final attached = off.abs() < d * 0.35 && m.kick < 0.82;
      moteArc.add(attached ? a : -1);
      moteOff.add(off);
    }
    return _Plan(n, arcs, bestTheta, serviceOf, moteArc, moteOff);
  }
}

/// Halka parçacığı: dönen çerçevede açı, banttaki yarıçap oranı, boy, parlaklık, hız katsayısı (içtekiler
/// biraz daha hızlı), rastgele 0..1 (saçılma, ömür, kuyruktaki yer), parlak çizgide mi.
class _Mote {
  const _Mote(this.theta, this.r, this.size, this.alpha, this.speed, this.kick, this.bright);

  final double theta, r, size, alpha, speed, kick;
  final bool bright;
}

/// Kırık yay: elipsin [a0, a1] aralığı; dışa savrulup söner.
class _Shard {
  const _Shard(this.c, this.a, this.b, this.tilt, this.a0, this.a1, this.v, this.width, this.alpha, this.life);

  final Offset c, v;
  final double a, b, tilt, a0, a1, width, alpha, life;
}

/// Halkayı oluşturan parçacıklar ve patlamada kırılan küre kenarı / yörünge parçaları. Tohumlu.
class _Debris {
  _Debris(this.motes, this.shards);

  final List<_Mote> motes;
  final List<_Shard> shards;

  static _Debris make() {
    final r = math.Random(5);
    final motes = <_Mote>[];
    for (var i = 0; i < 2600; i++) {
      final k = i % 100;
      // Bantlar: dışta parlak çizgi (%40), ortada yoğun bant (%35), içte ve dışta seyrek toz (%25).
      final (double rr, double size, double alpha) = k < 40
          ? (0.972 + r.nextDouble() * 0.05, 1.8 + r.nextDouble() * 1.8, 0.55 + r.nextDouble() * 0.45)
          : k < 75
              ? (0.875 + r.nextDouble() * 0.11, 1.3 + r.nextDouble() * 1.4, 0.30 + r.nextDouble() * 0.4)
              : (0.78 + r.nextDouble() * 0.30, 1.0 + r.nextDouble() * 1.2, 0.15 + r.nextDouble() * 0.30);
      motes.add(_Mote(r.nextDouble() * 2 * math.pi, rr, size, alpha, 1.06 - 0.12 * (rr - 0.8) / 0.27, r.nextDouble(), k < 40));
    }
    final shards = <_Shard>[];
    Offset out(Offset p, double speed) {
      final d = _unit(p - _G.star);
      return (d + Offset(-d.dy, d.dx) * ((r.nextDouble() - 0.5) * 0.5)) * speed;
    }

    void broken(Offset c, double a, double b, double tilt, int count, double gap, double speed, double width, double alpha, double life) {
      final d = 2 * math.pi / count;
      for (var k = 0; k < count; k++) {
        final a0 = k * d + r.nextDouble() * d * 0.2;
        final a1 = a0 + d * (1 - gap) * (0.7 + r.nextDouble() * 0.3);
        final mid = _G.ellipse(c, a, b, tilt, (a0 + a1) / 2);
        shards.add(_Shard(c, a, b, tilt, a0, a1, out(mid, speed * (0.6 + r.nextDouble() * 0.8)), width, alpha,
            life * (0.8 + r.nextDouble() * 0.4)));
      }
    }

    broken(_G.star, _G.sphereR, _G.sphereR, 0, 24, 0.08, 0.55, 3.2, 1.0, 0.8);
    broken(_G.star, _G.sphereR * 0.86, _G.sphereR * 0.86, 0, 14, 0.35, 0.4, 1.2, 0.4, 0.6);
    broken(_G.orbitCenter, _G.orbitA, _G.orbitB, _G.orbitTilt, 22, 0.15, 0.22, 1.2, 0.45, 0.8);
    broken(_G.star, _G.innerOrbitR, _G.innerOrbitR * 0.97, 0, 18, 0.45, 0.18, 1.0, 0.4, 0.75);
    return _Debris(motes, shards);
  }
}

/// Simgenin o karedeki yeri ve görünümü (kartın simge yeri; ölçek merkezden).
class _IconPose {
  const _IconPose(this.service, this.rect, this.alpha, this.scale);

  final AiService service;
  final Rect rect;
  final double alpha;
  final double scale;
}

/// Yayın kırılma pozu: orta açı, büyüme, daralma, orta noktası (ekran), dışa kayma, yatma, kamera ölçeği.
class _ArcPose {
  _ArcPose(this.mid, this.ex, this.shrink, this.m, this.drift, double rot, this.k)
      : rc = math.cos(rot),
        rs = math.sin(rot);

  final double mid, ex, shrink, k, rc, rs;
  final Offset m, drift;
}

/// Kartına uçan yayın yolu.
class _Flight {
  const _Flight(this.m0, this.ctrl, this.tc, this.e, this.w, this.tail);

  final Offset m0, ctrl, tc;
  final double e, w, tail;

  Offset path(double x) =>
      x <= 0 ? m0 + (ctrl - m0) * (2 * x) : m0 * ((1 - x) * (1 - x)) + ctrl * (2 * (1 - x) * x) + tc * (x * x);

  Offset get head => path(e);
}

/// Bir yayın o karedeki hâli.
class _Piece {
  _Piece(this.points, this.f, this.land, this.color, this.alpha, this.target, this.service, this.pose, this.flight);

  /// Baş önde (j = 0); uçuş başlamadıysa yayın kendisi.
  final List<Offset> points;
  final double f; // 0 kalkmadı, 0..1 uçuşta
  final double land; // iniş anı (s)
  final Color color;
  final double alpha;
  final Rect? target;
  final AiService? service;
  final _ArcPose pose;
  final _Flight? flight;
}

/// Bir karenin bütün geometrisi: boyacı ve simge katmanı aynı hesabı paylaşır.
class _Frame {
  _Frame(this.lay, double t, this.services, this.targets, this.plan, this.debris, this.space)
      : s = t * IntroTiming.seconds {
    final tr = _trauma(s);
    final k = tr * tr; // sarsıntı = travma²: küçük olay neredeyse sessiz, patlama belirgin
    shake = Offset(_fbm(s * 22), _fbm(s * 22 + 50)) * 12 * lay.u * k;
    shakeAngle = _fbm(s * 22 + 90) * 0.014 * k;
    _cs = math.cos(shakeAngle);
    _ss = math.sin(shakeAngle);
    hero = _heroScale();
    _punch = punchAt(s);
    darkness = 1 - Curves.easeInOutCubic.transform(_seg(s, IntroTiming.darkFrom, IntroTiming.darkTo));
    if (s >= IntroTiming.burst) _pieces();
  }

  static const _k = 32; // yay başına nokta
  static const _impact = 1.04; // patlama anında gezegen ölçeği

  final _Layout lay;
  final double s;
  final List<AiService> services;
  final Map<String, Rect> targets;
  final _Plan? plan;
  final _Debris debris;
  final ui.Image? space;
  late final Offset shake;
  late final double shakeAngle;
  late final double darkness;

  /// Kare başına bir kez: sarsıntının kosinüs/sinüsü, gezegen ölçeği, kamera yumruğu.
  late final double _cs, _ss, hero, _punch;
  final pieces = <_Piece>[];
  final icons = <_IconPose>[];

  double get u => lay.u;
  double get pu => lay.pu;
  double get side => lay.side;
  double get sinceBurst => s - IntroTiming.burst;

  /// Patlamadan sonra savrulma süresi (parlamanın tepesi durduktan sonra başlar).
  double get tb => math.max(0.0, s - IntroTiming.burst - IntroTiming.hold);

  double get appear => _ease(_seg(s, IntroTiming.appear, IntroTiming.appear + IntroTiming.appearDur));
  double get charge => _seg(s, IntroTiming.charge, IntroTiming.burst);

  /// Gezegenin ölçeği: belirirken küçük taşmayla oturur, hazırlıkta gerilir, patlamadan hemen önce içine çekilir.
  double _heroScale() {
    if (s >= IntroTiming.burst) return _impact * punchAt(s);
    final pop = 0.9 + 0.1 * Curves.easeOutBack.transform(_seg(s, IntroTiming.appear, IntroTiming.appear + 0.55));
    return pop * (1 + 0.025 * charge) * (1 - 0.06 * Curves.easeInCubic.transform(_seg(s, IntroTiming.burst - 0.12, IntroTiming.burst)));
  }

  /// Kamera "yumruğu": patlamada 50 ms'de %8 yakınlaşır, ~160 ms'de geri oturur.
  static double punchAt(double at) {
    final s1 = at - IntroTiming.burst;
    if (s1 <= 0) return 1;
    return 1 + 0.08 * _seg(s1, 0, 0.05) * math.exp(-math.max(0.0, s1 - 0.05) / 0.16);
  }

  /// Çekirdeğin nabzı: frekans 1,2 Hz'den ~6 Hz'e çıkar.
  double get pulse {
    final x = math.min(s, IntroTiming.burst);
    return 0.5 + 0.5 * math.sin(2 * math.pi * (1.2 * x + 1.6 * x * x));
  }

  static double _trauma(double s) {
    // Hazırlıkta yükselir, patlamada sıçrar, doğrusal söner (1,5/sn).
    if (s < IntroTiming.burst) return 0.34 * Curves.easeIn.transform(_seg(s, IntroTiming.charge + 0.3, IntroTiming.burst));
    return math.max(0.0, 0.90 - (s - IntroTiming.burst) * 1.5);
  }

  // Yumuşatılmış değer gürültüsü: tekrar oynatımda (ALLAI_INTRO_T) aynı kare.
  static double _hash(double i) {
    final x = math.sin(i * 127.1 + 311.7) * 43758.5453;
    return x - x.floorToDouble();
  }

  static double _noise(double x) {
    final i = x.floorToDouble(), f = x - i;
    final w = f * f * (3 - 2 * f);
    return (_hash(i) * (1 - w) + _hash(i + 1) * w) * 2 - 1;
  }

  static double _fbm(double x) => _noise(x) * 0.7 + _noise(x * 2.3 + 17) * 0.3;

  Offset _place(Offset g, double k) {
    final vx = (g.dx - _G.star.dx) * k, vy = (g.dy - _G.star.dy) * k;
    return Offset(lay.center.dx + shake.dx + vx * _cs - vy * _ss, lay.center.dy + shake.dy + vx * _ss + vy * _cs);
  }

  /// Gezegen koordinatından ekrana, sarsıntı ve ölçekle.
  Offset scr(Offset g, [double scale = 1]) => _place(g, side * scale * hero);

  /// Patlama sonrası (sarsıntılı, kamera yumruklu) gezegen koordinatından ekrana.
  Offset bAt(Offset g, double at, [double scale = 1]) => _place(g, side * scale * _impact * (at == s ? _punch : punchAt(at)));

  /// Yayın [at] anındaki kırılma pozu: boşluklar açılır, halka biraz büyür ve dönmeyi sönerek sürdürür,
  /// her yay dışa kayar ve kendi ortasında hafifçe yatar.
  _ArcPose arcPose(int a, double at) {
    final p = plan!;
    final t = math.max(0.0, at - IntroTiming.burst - IntroTiming.hold);
    final shrink = 1 - 0.30 * _ease(_seg(t, 0, 0.28));
    final ex = 1 + 0.22 * _ease(_seg(t, 0, 0.6));
    final mid = p.mid(a) + _ringAngle(at);
    final k = _impact * punchAt(at);
    final m = lay.at(_G.ring(mid, ex), k);
    final drift = _unit(m - lay.center) * 50 * u * _ease(_seg(t, 0, 0.5));
    final rot = (a.isEven ? 1 : -1) * 0.20 * _ease(_seg(t, 0, 0.7));
    return _ArcPose(mid, ex, shrink, m, drift, rot, k);
  }

  /// Yayın üzerindeki nokta: ortaya göre açı [off], banttaki yarıçap oranı [r].
  Offset onArc(_ArcPose p, double off, double r) {
    final q = lay.at(_G.ring(p.mid + off * p.shrink, r * p.ex), p.k) - p.m;
    return Offset(p.m.dx + p.drift.dx + q.dx * p.rc - q.dy * p.rs + shake.dx, p.m.dy + p.drift.dy + q.dx * p.rs + q.dy * p.rc + shake.dy);
  }

  List<Offset> arc(int a, double at) {
    final pose = arcPose(a, at);
    final span = plan!.span;
    return [for (var j = 0; j < _k; j++) onArc(pose, -span / 2 + span * j / (_k - 1), 1.0)];
  }

  void _pieces() {
    final p = plan;
    if (p == null) return;
    for (var a = 0; a < p.arcs; a++) {
      final i = p.serviceOf[a];
      final svc = i >= 0 ? services[i] : null;
      final fs = IntroTiming.flightStart(i >= 0 ? i : a, i >= 0 ? services.length : p.arcs);
      final land = fs + IntroTiming.flightDur;
      final f = _seg(s, fs, land);
      final target = svc == null ? null : targets[svc.id];
      final brand = svc == null ? Colors.white : Color.lerp(svc.color, svc.accent, 0.25)!;
      final pose = arcPose(a, s);
      var pts = arc(a, s);
      var alpha = 1.0;
      var color = Colors.white;
      _Flight? flight;
      if (f > 0) {
        final start = arc(a, fs);
        final m0 = start[_k ~/ 2];
        final dir = _unit(m0 - lay.center);
        final tc = target?.center ?? m0 + dir * 900 * u;
        final ctrl = m0 + dir * 150 * u + (tc - m0) * 0.25;
        // Baş, uçuş yönüne bakan uç olsun.
        final dl = start.last - m0, df = start.first - m0, dc = ctrl - m0;
        if (dl.dx * dc.dx + dl.dy * dc.dy > df.dx * dc.dx + df.dy * dc.dy) pts = pts.reversed.toList();
        flight = _Flight(m0, ctrl, tc, Motion.flight.transform(f), Curves.easeInOut.transform(_seg(f, 0, 0.35)),
            0.32 * math.pow(math.sin(math.pi * f), 0.7));
        final fl = flight;
        // Yay kalkışta kuyruklu yıldıza açılır; kuyruk yolun arkasında uzar, inişte noktaya toplanır.
        pts = [
          for (var j = 0; j < _k; j++) Offset.lerp(pts[j] + (fl.head - m0), fl.path(fl.e - fl.tail * j / (_k - 1)), fl.w)!,
        ];
        color = Color.lerp(Colors.white, brand, _smooth(0.30, 0.90, f))!;
        if (target == null) alpha = 1 - fl.e;
      }
      pieces.add(_Piece(pts, f, land, color, alpha, target, svc, pose, flight));
      // Simge, yay çarpmadan az önce yerinde belirir; küçük taşmayla oturur (taşma ≈ %4).
      if (svc != null && target != null) {
        final ip = _seg(s, land - 0.08, land + 0.24);
        if (ip > 0) {
          icons.add(_IconPose(svc, target, Curves.easeOut.transform(_seg(s, land - 0.08, land + 0.04)),
              0.55 + 0.45 * Motion.springOut.transform(ip)));
        }
      }
    }
  }
}

void _atlas(Canvas c, ui.Image? img, List<double> xf, List<int> col) {
  if (col.isEmpty || img == null) return;
  final src = Float32List(col.length * 4);
  for (var i = 0; i < col.length; i++) {
    src[i * 4 + 2] = img.width.toDouble();
    src[i * 4 + 3] = img.height.toDouble();
  }
  c.drawRawAtlas(img, Float32List.fromList(xf), src, Int32List.fromList(col), BlendMode.modulate, null,
      Paint()
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.low);
}

void _put(List<double> xf, List<int> col, ui.Image? img, Offset p, double size, Color c) {
  if (img == null || size <= 0.1 || c.a <= 0.004) return;
  xf
    ..add(size / img.width)
    ..add(0)
    ..add(p.dx - size / 2)
    ..add(p.dy - size / 2);
  col.add(c.toARGB32());
}

/// Döndürülmüş sprite (hız çizgisi): [len] boyunda, [angle] yönünde, ortası [p]'de.
void _putRot(List<double> xf, List<int> col, ui.Image img, Offset p, double len, double angle, Color c) {
  if (len <= 0.5 || c.a <= 0.004) return;
  final k = len / img.width;
  final cs = math.cos(angle) * k, sn = math.sin(angle) * k;
  final w = img.width / 2, h = img.height / 2;
  xf
    ..add(cs)
    ..add(sn)
    ..add(p.dx - (cs * w - sn * h))
    ..add(p.dy - (sn * w + cs * h));
  col.add(c.toARGB32());
}

/// Elips çizgisi (ekran noktaları).
List<Offset> _ellipsePts(Offset Function(Offset g) map, Offset c, double a, double b, double tilt, int n, [double a0 = 0, double a1 = 2 * math.pi]) =>
    [for (var j = 0; j <= n; j++) map(_G.ellipse(c, a, b, tilt, a0 + (a1 - a0) * j / n))];

/// Bütün açılış tek boyacıda: zemin, gezegen (arka halka → küre → çekirdek → ön halka) ya da patlama
/// sonrası (yaylar, kırıklar, enkaz, varış darbeleri), parlama ve şok dalgaları.
class _IntroPainter extends CustomPainter {
  _IntroPainter(this.f);

  final _Frame f;

  @override
  void paint(Canvas c, Size size) {
    _backdrop(c, size);
    if (f.s < IntroTiming.burst) {
      _planet(c);
    } else {
      _broken(c);
    }
    _arrivals(c);
    _flash(c, size);
  }

  /// Siyah örtü + sakin kozmik boşluk (kaplar, dönmez); patlamadan sonra ana ekrana açılır.
  void _backdrop(Canvas c, Size size) {
    if (f.darkness > 0.002) c.drawRect(Offset.zero & size, Paint()..color = Colors.black.withValues(alpha: f.darkness));
    final img = f.space;
    final a = f.appear * f.darkness;
    if (img == null || a <= 0.004) return;
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final k = math.max(size.width / iw, size.height / ih);
    c.drawImageRect(img, Rect.fromLTWH(0, 0, iw, ih), Rect.fromCenter(center: size.center(Offset.zero), width: iw * k, height: ih * k),
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Colors.white.withValues(alpha: a));
  }

  void _planet(Canvas c) {
    final op = f.appear;
    if (op <= 0.003) return;
    final pu = f.pu * f.hero;
    final side = f.side * f.hero;
    final ch = f.charge;
    final rot = _ringAngle(f.s);
    final spin = _spinAt(f.s);
    final glow = 0.85 + 0.5 * ch * ch; // halka parlaklığı (gerilim)
    final sc = f.scr(_G.star);
    final r = _G.sphereR * side;
    final back = GlowStrips(), front = GlowStrips();
    final dot = Sprites.dot;
    final bx = <double>[], bc = <int>[], fx = <double>[], fc = <int>[];
    final sx = <double>[], scl = <int>[], spx = <double>[], spc = <int>[];

    // Uzak ayrıntılar: sarmal galaksiler, aylar (hilal), dört köşeli parıltılar, ince yörüngeler ve boncuklar.
    for (final g in _G.galaxies) {
      Sprites.paint(c, Sprites.glow, Rect.fromCenter(center: f.scr(g), width: side * 0.16, height: side * 0.06),
          const Color(0xFFDDE4FF).withValues(alpha: 0.35 * op), rotation: -0.5, blend: BlendMode.plus);
      _put(bx, bc, dot, f.scr(g), side * 0.02, Colors.white.withValues(alpha: 0.7 * op));
    }
    for (final (p, rad) in _G.moons) {
      final mc = f.scr(p);
      final mr = rad * side;
      c.drawCircle(mc, mr, Paint()..color = const Color(0xFF9A9AA4).withValues(alpha: 0.55 * op));
      c.drawCircle(mc.translate(mr * 0.32, mr * 0.18), mr * 0.95, Paint()..color = const Color(0xFF060608).withValues(alpha: op));
    }
    final sp = Sprites.sparkle;
    for (var k = 0; k < _G.sparkles.length; k++) {
      final (p, len) = _G.sparkles[k];
      final tw = 0.6 + 0.4 * math.sin(f.s * 3 + k * 1.7);
      _put(spx, spc, sp, f.scr(p), len * side * 2.4 * (0.85 + 0.25 * tw), Colors.white.withValues(alpha: (0.9 * tw * op).clamp(0.0, 1.0)));
    }
    for (final (cen, a, b, tilt) in const [
      (_G.orbitCenter, _G.orbitA, _G.orbitB, _G.orbitTilt),
      (_G.star, _G.innerOrbitR, _G.innerOrbitR * 0.97, 0.0),
    ]) {
      final pts = _ellipsePts(f.scr, cen, a, b, tilt, 120);
      back
        ..add(pts, (_) => 5 * pu, (_) => Colors.white.withValues(alpha: 0.06 * op))
        ..add(pts, (_) => 1.4 * pu, (_) => Colors.white.withValues(alpha: 0.40 * op));
    }
    for (var k = 0; k < _G.beads.length; k++) {
      final t = k * 1.3 + rot * 0.12;
      final p = k.isEven
          ? _G.ellipse(_G.orbitCenter, _G.orbitA, _G.orbitB, _G.orbitTilt, t)
          : _G.ellipse(_G.star, _G.innerOrbitR, _G.innerOrbitR * 0.97, 0, t);
      _put(bx, bc, dot, f.scr(p), 16 * pu, Colors.white.withValues(alpha: 0.95 * op));
    }

    // Halka bantları: dışta kalın parlak çizgi, içte yoğun ve sönük bantlar; aydınlık bölgeler dönüşle akar.
    for (final (rr, a0, w) in const [(1.035, 0.22, 1.2), (1.0, 1.0, 3.0), (0.955, 0.55, 2.0), (0.91, 0.40, 2.2), (0.86, 0.26, 2.0)]) {
      for (final isFront in const [false, true]) {
        const n = 90;
        final th = [for (var j = 0; j <= n; j++) (isFront ? 0.0 : math.pi) + j / n * math.pi];
        final pts = [for (final t in th) f.scr(_G.ring(t, rr))];
        double flow(int j) => 0.6 + 0.4 * math.sin(3 * (th[j] - rot));
        final depth = isFront ? 1.0 : 0.55;
        (isFront ? front : back)
          ..add(pts, (_) => 7 * w * pu, (j) => Colors.white.withValues(alpha: (0.14 * a0 * glow * depth * op * flow(j)).clamp(0.0, 1.0)))
          ..add(pts, (_) => w * pu, (j) => Colors.white.withValues(alpha: (a0 * glow * depth * op * flow(j)).clamp(0.0, 1.0)));
      }
    }
    // Halkada koşan ışık izleri (halkadan 1,6 kat hızlı); arka yarıda sönük.
    for (var h = 0; h < 6; h++) {
      const n = 22;
      final head = rot * 1.6 + h * math.pi / 3;
      final th = [for (var j = 0; j < n; j++) head - (0.6 + 0.6 * ch) * (1 - j / (n - 1))];
      final rr = 0.92 + 0.03 * (h % 3);
      for (final isFront in const [false, true]) {
        final pts = [for (final t in th) f.scr(_G.ring(t, rr))];
        double a(int j) {
          if ((math.sin(th[j]) > 0) != isFront) return 0;
          return math.pow(j / (n - 1), 1.6) * (0.45 + 0.55 * ch) * op * (isFront ? 1 : 0.5);
        }

        (isFront ? front : back)
          ..add(pts, (_) => 10 * pu, (j) => Colors.white.withValues(alpha: (0.3 * a(j)).clamp(0.0, 1.0)))
          ..add(pts, (_) => 2.6 * pu, (j) => Colors.white.withValues(alpha: a(j).clamp(0.0, 1.0)));
      }
    }

    // Parçacıklar (dönen çerçevede açı); hızlanınca parlak olanlar teğet yönde hız çizgisi bırakır.
    final st = _Art.streak;
    for (final m in f.debris.motes) {
      final t = m.theta + rot * m.speed;
      final isFront = math.sin(t) > 0;
      final p = f.scr(_G.ring(t, m.r));
      final a = (m.alpha * glow * op * (isFront ? 1 : 0.5)).clamp(0.0, 1.0);
      _put(isFront ? fx : bx, isFront ? fc : bc, dot, p, m.size * 3.0 * pu * (1 + 0.3 * ch), Colors.white.withValues(alpha: a));
      if (st != null && m.bright && m.kick < 0.45 && spin > 1.5) {
        // Boy, o noktadaki yörünge hızıyla orantılı (halkanın uçlarında kısa, önde ve arkada uzun).
        final tg = f.scr(_G.ring(t + 0.01, m.r)) - p;
        final len = tg.distance / 0.01 * spin * 0.024 * (0.6 + m.kick);
        final occluded = !isFront && (p - sc).distance < r;
        if (!occluded) {
          _putRot(sx, scl, st, p - _unit(tg) * len * 0.45, len, math.atan2(tg.dy, tg.dx),
              Colors.white.withValues(alpha: (a * 0.55 * _seg(spin, 1.5, 5)).clamp(0.0, 1.0)));
        }
      }
    }

    back.paint(c);
    _atlas(c, dot, bx, bc);
    // Küre: geniş hale, hacimli gövde (arka halkayı örter), kalın parlak jant + dış ışıma.
    Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: sc, radius: r * 2.6),
        Colors.white.withValues(alpha: (0.16 + 0.18 * ch) * op), blend: BlendMode.plus);
    final sph = _Art.sphere;
    if (sph != null) {
      c.drawImageRect(sph, Rect.fromLTWH(0, 0, sph.width.toDouble(), sph.height.toDouble()), Rect.fromCircle(center: sc, radius: r),
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Colors.white.withValues(alpha: op));
    }
    Sprites.paint(c, Sprites.ring, Rect.fromCircle(center: sc, radius: r * 1.10 / 0.92),
        Colors.white.withValues(alpha: (0.30 + 0.25 * ch) * op), blend: BlendMode.plus);
    Sprites.paint(c, Sprites.ring, Rect.fromCircle(center: sc, radius: r / 0.92),
        Colors.white.withValues(alpha: (0.85 + 0.15 * ch) * op), blend: BlendMode.plus);
    c.drawCircle(sc, r * 0.995, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4 * pu
      ..color = Colors.white.withValues(alpha: op));
    // Çekirdek: ışınlı parlak yıldız, nabız gibi atar, hazırlıkta büyür.
    final pl = f.pulse;
    Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: sc, radius: r * (0.42 + 0.14 * pl * (0.3 + ch) + 0.4 * ch * ch)),
        Colors.white.withValues(alpha: ((0.6 + 0.2 * pl + 0.2 * ch) * op).clamp(0.0, 1.0)), blend: BlendMode.plus);
    if (sp != null) {
      final w = r * (1.0 + 1.6 * ch) * (0.92 + 0.08 * pl);
      c.save();
      c.translate(sc.dx, sc.dy);
      c.rotate(-rot * 0.2);
      c.drawImageRect(sp, Rect.fromLTWH(0, 0, sp.width.toDouble(), sp.height.toDouble()), Rect.fromCenter(center: Offset.zero, width: w, height: w),
          Paint()
            ..blendMode = BlendMode.plus
            ..filterQuality = FilterQuality.low
            ..color = Colors.white.withValues(alpha: ((0.55 + 0.4 * ch) * op).clamp(0.0, 1.0)));
      c.restore();
    }
    Sprites.paint(c, Sprites.dot, Rect.fromCircle(center: sc, radius: r * (0.16 + 0.04 * pl + 0.08 * ch)),
        Colors.white.withValues(alpha: op), blend: BlendMode.plus);
    c.drawCircle(sc, r * 0.08, Paint()..color = Colors.white.withValues(alpha: op));
    front.paint(c);
    _atlas(c, dot, fx, fc);
    if (st != null) _atlas(c, st, sx, scl);
    _atlas(c, sp, spx, spc);
    // Çekirdekten yatay ışık çizgisi (gerilimle uzar).
    Sprites.paint(c, Sprites.glow, Rect.fromCenter(center: sc, width: f.lay.size.width * (0.45 + 0.8 * ch), height: 7 * f.u),
        Colors.white.withValues(alpha: (0.22 + 0.45 * ch) * op), blend: BlendMode.plus);
  }

  void _broken(Canvas c) {
    final s1 = f.sinceBurst;
    final tb = f.tb;
    final u = f.u;
    final pu = f.pu;
    final side = f.side;
    final plan = f.plan;
    final star = f.bAt(_G.star, f.s);
    final r = _G.sphereR * side * _Frame._impact * _Frame.punchAt(f.s);
    // Küre gövdesi parlamanın altında söner; çekirdek sönen artık ışık olur.
    final bodyA = 1 - _seg(s1, 0, 0.14);
    final sph = _Art.sphere;
    if (bodyA > 0.004 && sph != null) {
      c.drawImageRect(sph, Rect.fromLTWH(0, 0, sph.width.toDouble(), sph.height.toDouble()), Rect.fromCircle(center: star, radius: r),
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Colors.white.withValues(alpha: bodyA));
    }
    final glowA = math.pow(1 - _seg(s1, 0, 0.7), 2).toDouble();
    if (glowA > 0.004) {
      Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: star, radius: r * (3.0 - 1.8 * _seg(s1, 0, 0.6))),
          Colors.white.withValues(alpha: 0.95 * glowA), blend: BlendMode.plus);
    }

    final strips = GlowStrips();
    // Küre kenarı ve yörünge kırıkları (kalın, ışıklı).
    final drag = (1 - math.exp(-3 * tb)) / 3;
    for (final sh in f.debris.shards) {
      final a = sh.alpha * (1 - _smooth(0.35, 1.0, tb / sh.life));
      if (a <= 0.01) continue;
      final off = sh.v * drag;
      const n = 7;
      final pts = [
        for (var j = 0; j < n; j++) f.bAt(_G.ellipse(sh.c, sh.a, sh.b, sh.tilt, sh.a0 + (sh.a1 - sh.a0) * j / (n - 1)) + off, f.s),
      ];
      strips
        ..add(pts, (_) => sh.width * pu * 4, (_) => Colors.white.withValues(alpha: 0.22 * a))
        ..add(pts, (_) => sh.width * pu, (j) => Colors.white.withValues(alpha: a * (j == 0 || j == n - 1 ? 0.4 : 1)));
    }
    // Halka yayları: kalın parlak çekirdek, ışıklı gövde, geniş hale; kırılırken içte tozlu ikinci bant.
    for (final p in f.pieces) {
      if (p.alpha <= 0.01 || p.f >= 1) continue;
      final k = p.points.length;
      final morph = p.flight?.w ?? 0;
      double along(int j) {
        final x = j / (k - 1);
        final ends = _smooth(0, 0.15, x) * (1 - _smooth(0.85, 1, x));
        final comet = math.pow(1 - x, 1.4).toDouble();
        return ui.lerpDouble(ends, comet, morph)!;
      }

      final thin = 1 - 0.45 * _smooth(0.75, 1, p.f);
      final hw = (5.0 + 2.0 * math.sin(math.pi * p.f)) * thin * pu;
      strips
        ..add(p.points, (j) => hw * 6, (j) => p.color.withValues(alpha: 0.20 * p.alpha * along(j)))
        ..add(p.points, (j) => hw * 2.2, (j) => p.color.withValues(alpha: 0.45 * p.alpha * along(j)))
        ..add(p.points, (j) => hw, (j) => p.color.withValues(alpha: p.alpha * along(j)));
      if (p.f <= 0) {
        final inner = [for (final q in p.points) Offset.lerp(star, q, 0.91)!];
        strips.add(inner, (_) => 5 * pu, (j) => Colors.white.withValues(alpha: 0.35 * (1 - _seg(tb, 0.15, 0.55)) * along(j)));
      }
    }
    strips.paint(c);

    // Halka parçacıkları: yayın ortasındakiler yayla gider (uçuşta kuyruk tozu olur), kenardakiler kıvılcım
    // olup saçılır; uçan yayların başında inişe doğru büyüyen marka renkli ışık.
    final xf = <double>[], cl = <int>[];
    if (plan != null) {
      final rotB = _ringAngle(IntroTiming.burst);
      final d = (1 - math.exp(-2.5 * tb)) / 2.5;
      final motes = f.debris.motes;
      for (var i = 0; i < motes.length; i++) {
        final m = motes[i];
        final a = plan.moteArc[i];
        if (a >= 0 && a < f.pieces.length) {
          final pc = f.pieces[a];
          var pos = f.onArc(pc.pose, plan.moteOff[i], m.r);
          var al = m.alpha;
          var col = Colors.white;
          final fl = pc.flight;
          if (fl != null) {
            final jitter = Offset(math.cos(m.theta * 7), math.sin(m.theta * 5)) * (16 * u * (1 - fl.e));
            pos = Offset.lerp(pos + (fl.head - fl.m0), fl.path(fl.e - (fl.tail + 0.08) * m.kick) + jitter, fl.w)!;
            al *= (1 - _smooth(0.25, 0.85, pc.f)) * pc.alpha;
            col = pc.color;
          }
          _put(xf, cl, Sprites.dot, pos, m.size * 3.0 * pu, col.withValues(alpha: al.clamp(0.0, 1.0)));
          continue;
        }
        final life = 0.45 + 0.6 * m.kick;
        final al = m.alpha * (1 - _smooth(life * 0.3, life, tb));
        if (al <= 0.01) continue;
        final p0 = f.bAt(_G.ring(m.theta + rotB * m.speed, m.r), f.s);
        final rel = p0 - star;
        final v = _unit(rel) * ((0.25 + 0.8 * m.kick) * side * 0.5) + Offset(-rel.dy, rel.dx) * (_spinB * 0.4);
        _put(xf, cl, Sprites.dot, p0 + v * d, m.size * 3.0 * pu * (1 - 0.4 * _seg(tb, 0, life)), Colors.white.withValues(alpha: al));
      }
    }
    for (final p in f.pieces) {
      if (p.f <= 0 || p.alpha <= 0.01) continue;
      final fade = 1 - _seg(f.s, p.land, p.land + 0.14);
      if (fade <= 0) continue;
      final w = p.target?.width ?? 40 * u;
      _put(xf, cl, Sprites.dot, p.points.first, ui.lerpDouble(40 * u, w * 1.8, _smooth(0.55, 1.0, p.f))!,
          p.color.withValues(alpha: ((0.7 + 0.3 * _smooth(0.5, 1.0, p.f)) * fade * p.alpha).clamp(0.0, 1.0)));
      // Yolun gerisinde sönen kıvılcımlar.
      final fl = p.flight!;
      for (var k = 1; k <= 6; k++) {
        final x = fl.e - k * 0.05;
        if (x <= 0) break;
        final q = fl.path(x) + Offset(math.sin(k * 2.1 + p.land * 9), math.cos(k * 1.7 + p.land * 7)) * (8 * u * k / 6);
        _put(xf, cl, Sprites.dot, q, (9 - k) * u, p.color.withValues(alpha: (0.8 * (1 - k / 7) * fade * p.alpha).clamp(0.0, 1.0)));
      }
    }
    _atlas(c, Sprites.dot, xf, cl);
  }

  /// Yay kartına çarptığında: genişleyen darbe halkası, beyaz parlama, marka renkli ışık, saçılan kıvılcımlar.
  void _arrivals(Canvas c) {
    final xf = <double>[], col = <int>[];
    final rings = GlowStrips();
    for (final p in f.pieces) {
      final t = p.target;
      final svc = p.service;
      if (t == null || svc == null) continue;
      final b = _seg(f.s, p.land - 0.02, p.land + 0.40);
      if (b <= 0 || b >= 1) continue;
      final w = t.width;
      final e = _ease(b);
      final rr = w * (0.5 + 1.5 * e);
      final ra = (1 - b) * (1 - b);
      final pts = [for (var j = 0; j <= 48; j++) t.center + Offset(math.cos(j / 48 * 2 * math.pi), math.sin(j / 48 * 2 * math.pi)) * rr];
      final rc = Color.lerp(Colors.white, svc.color, 0.35)!;
      rings
        ..add(pts, (_) => 14 * f.u, (_) => rc.withValues(alpha: 0.30 * ra))
        ..add(pts, (_) => 3.0 * f.u, (_) => rc.withValues(alpha: 0.95 * ra));
      Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: t.center, radius: w * 1.4),
          svc.color.withValues(alpha: 0.55 * (1 - b)), blend: BlendMode.plus);
      Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: t.center, radius: w * 1.0),
          Colors.white.withValues(alpha: 0.85 * (1 - _seg(b, 0, 0.35))), blend: BlendMode.plus);
      for (var k = 0; k < 14; k++) {
        final a = k / 14 * 2 * math.pi + t.center.dx * 0.01;
        final q = t.center + Offset(math.cos(a), math.sin(a)) * (w * (0.45 + 1.3 * e));
        _put(xf, col, Sprites.dot, q, 9 * f.u * (1 - 0.5 * b),
            Color.lerp(Colors.white, svc.accent, k.isEven ? 0.2 : 0.7)!.withValues(alpha: 0.95 * (1 - b)));
      }
    }
    rings.paint(c);
    _atlas(c, Sprites.dot, xf, col);
  }

  /// Patlama: ortası beyaz ışık (tepesi [IntroTiming.hold] boyunca durur, ~80 ms'lik üstel sönüm), çok kısa
  /// düz örtü, ekranı yatay kesen ışık çizgisi, kalın şok dalgaları (ekran düzleminde çember + halka
  /// düzleminde eğik elips; keskin çizgi + yumuşak bant). Tek parlama (< 3/sn ışık hassasiyeti sınırı içinde).
  void _flash(Canvas c, Size size) {
    final s1 = f.sinceBurst;
    if (s1 < 0) return;
    final lay = f.lay;
    final waves = GlowStrips();
    final sw = _seg(s1, 0, 0.65);
    if (sw > 0 && sw < 1) {
      final r = f.side * 0.15 + math.max(size.width, size.height) * 0.8 * _ease(sw);
      final a = (1 - sw) * (1 - sw);
      Sprites.paint(c, Sprites.ring, Rect.fromCircle(center: lay.center, radius: r * 1.04),
          Colors.white.withValues(alpha: 0.35 * a), blend: BlendMode.plus);
      final pts = [for (var j = 0; j <= 120; j++) lay.center + Offset(math.cos(j / 120 * 2 * math.pi), math.sin(j / 120 * 2 * math.pi)) * r];
      waves
        ..add(pts, (_) => 34 * f.u, (_) => Colors.white.withValues(alpha: 0.25 * a))
        ..add(pts, (_) => 5 * f.u, (_) => Colors.white.withValues(alpha: 0.95 * a));
    }
    final pw = _seg(s1, 0, 0.55);
    if (pw > 0 && pw < 1) {
      final k = 1 + 2.2 * _ease(pw);
      final a = (1 - pw) * (1 - pw);
      final pts = [for (var j = 0; j <= 120; j++) lay.at(_G.ring(j / 120 * 2 * math.pi, k), _Frame._impact)];
      waves
        ..add(pts, (_) => 30 * f.u, (_) => Colors.white.withValues(alpha: 0.28 * a))
        ..add(pts, (_) => 4.5 * f.u, (_) => Colors.white.withValues(alpha: 0.95 * a));
    }
    waves.paint(c);
    final streak = math.exp(-s1 / 0.14);
    if (streak > 0.01) {
      Sprites.paint(c, Sprites.glow, Rect.fromCenter(center: lay.center, width: size.width * (1.1 + 0.8 * _seg(s1, 0, 0.3)), height: 18 * f.u),
          Colors.white.withValues(alpha: 0.9 * streak), blend: BlendMode.plus);
    }
    final fl = s1 < IntroTiming.hold ? 1.0 : math.exp(-(s1 - IntroTiming.hold) / 0.08);
    if (fl < 0.003) return;
    final veil = s1 < IntroTiming.hold ? 1.0 : math.exp(-(s1 - IntroTiming.hold) / 0.035);
    if (veil > 0.01) {
      c.drawRect(Offset.zero & size, Paint()
        ..color = Colors.white.withValues(alpha: 0.22 * veil)
        ..blendMode = BlendMode.plus);
    }
    Sprites.paint(c, Sprites.glow, Rect.fromCircle(center: lay.center, radius: math.max(size.width, size.height) * 0.6),
        Colors.white.withValues(alpha: 0.85 * fl), blend: BlendMode.plus);
  }

  @override
  bool shouldRepaint(_IntroPainter old) => true;
}
