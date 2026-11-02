import 'package:flutter/animation.dart';

/// Hareket jetonları: süreler ve eğriler tek yerde.
abstract final class Motion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 460);
  static const expand = Duration(milliseconds: 540);
  static const collapse = Duration(milliseconds: 420);

  /// Material 3 "emphasized" ailesi.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve decelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Curve accelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  /// Hafif taşmalı yay (kartların yerine oturması, açılır pencere).
  static const Curve springOut = Cubic(0.34, 1.36, 0.64, 1.0);

  // --- Açılış, ana ekran, canlı zemin ---
  // Yumuşatmalar üstel: x += (hedef - x) * (1 - e^(-k*dt)); kare hızından bağımsız.
  // k = 2.3 / (hedefe %90 yaklaşma süresi, s).

  /// Açılışın toplam süresi (IntroTiming.seconds ile aynı); tıklama/tuşla atlanır.
  static const intro = Duration(milliseconds: 3200);

  /// Atlanınca ilk uçuşa kadar hızlı sarma; uçuşlar [introSkipRate] kat hızlı oynar
  /// (tekrar açan kullanıcı ≤ 0,65 sn bekler; uçuş atlanmaz, ana ekrana köprüdür).
  static const introSkip = Duration(milliseconds: 160);
  static const introSkipRate = 3.2;

  /// Parçaların karta uçuşu: hızlanarak kalkar, yerine yumuşak oturur.
  static const Curve flight = Cubic(0.3, 0.0, 0.0, 1.0);

  /// Zemin akışı ve boşta "nefes" saatinin tavanı. Yavaş akış 30 Hz'de fark edilmez; GPU işi yarıya iner.
  static const ambientHz = 30.0;

  /// Hover girişi ~165 ms'de %90 (NN/g: ≤ 100 ms'de tepki başlar, burada ilk karede başlıyor).
  static const hoverK = 14.0;

  /// Eğilme ve manyetik çekim imleci yakından izler (~130 ms).
  static const tiltK = 18.0;

  /// Komşu kartlar daha ağır (~255 ms): önce hover'daki kart, sonra çevresi tepki verir.
  static const neighborK = 9.0;

  /// Basma anlık hissettirmeli (~75 ms).
  static const pressK = 30.0;

  /// Zemin ışığı imleci gecikmeli izler (~230 ms); ton kartın rengine yavaş kayar (~770 ms).
  static const glowK = 10.0;
  static const tintK = 3.0;

  /// Kart hover pozu: yükselme (px), büyüme, basınca küçülme, en büyük 3B eğilme (rad).
  static const hoverLift = 10.0;
  static const hoverScale = 0.03;
  static const pressScale = 0.045;
  static const tilt = 0.14;

  /// Manyetik çekim (kart imlece en çok bu kadar px yaklaşır) ve komşu itme (px).
  static const magnet = 7.0;
  static const neighborPush = 6.0;

  /// Konik kenar ışığının tam turu (s): yavaş dönüş "canlı" okunur, dikkat dağıtmaz.
  static const borderSpin = 3.6;

  /// Boşta simge nefesi: periyot (s) ve genlik (px). Sık görülür, o yüzden silik.
  static const breathePeriod = 5.2;
  static const breatheAmp = 2.2;

  /// Basınca ışık dalgası ve hover girişinde tek seferlik ışık süpürmesi (s).
  static const ripple = 0.52;
  static const sweep = 0.9;
}
