import 'dart:math' as math;

/// Açılış zaman çizelgesi (saniye); denetleyici değeri 0..1 = 0..[seconds] (`Motion.intro`).
/// Izgara da kartlarını bu çizelgeyle açar: her kart, kendi parçası inerken çevresinde belirir.
abstract final class IntroTiming {
  /// Toplam süre; `Motion.intro` ile aynı.
  static const seconds = 3.2;

  /// Kozmik boşluk ve ortadaki gezegen karanlıktan belirir.
  static const appear = 0.0;
  static const appearDur = 0.40;

  /// Halka dönmeye başlar ve giderek hızlanır; [charge]'dan sonra çekirdek hızlanan nabızla parlar,
  /// halka gerilir, hafif titreşim; patlamadan hemen önce içine çekilir.
  static const charge = 0.75;

  /// Patlama: beyaz parlama + şok dalgası, halka yaylara kopar, küre kırılır. [hold] boyunca parlamanın
  /// tepesi durur (vuruş durdurma ≈ 4 kare; ölçü gerçek zamanda, kare sayısı 60 Hz içindir).
  static const burst = 1.50;
  static const hold = 0.06;

  /// İlk yay kartına uçmaya başlar (başlık ve köşe öğeleri de bu anda gelir); her uçuş [flightDur].
  static const flight0 = 1.70;
  static const flightDur = 0.62;

  /// Son yay en geç burada iner (çok kartta aralık sıkışır).
  static const landBy = 2.80;

  /// Karanlık açılır, zemin ve ana ekran parçaların arkasından görünür.
  static const darkFrom = 1.60;
  static const darkTo = 2.45;

  /// Saniyeden denetleyici değerine.
  static double at(double sec) => sec / seconds;

  /// Uçuşlar arası gecikme (s).
  static double stagger(int n) => n <= 1 ? 0 : math.min(0.055, (landBy - flightDur - flight0) / (n - 1));

  /// i'inci kartın yayının kalkış anı (s).
  static double flightStart(int i, int n) => flight0 + i * stagger(n);

  /// i'inci kartın belirme ilerlemesi ([t] 0..1): yay inmeden az önce başlar, inişten ~0,2 sn sonra biter.
  static double bloom(int i, int n, double t) =>
      ((t * seconds - flightStart(i, n) - flightDur * 0.8) / 0.32).clamp(0.0, 1.0);
}
