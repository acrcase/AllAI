import 'package:flutter/material.dart';

/// Renk jetonları. Uygulamanın her yerinde yalnız bunlar kullanılır.
abstract final class AppColors {
  // Kozmik siyah-beyaz tema: derin siyah zemin, gümüş vurgu; marka renkleri yalnız kartlarda ve hover tonunda.
  static const bg = Color(0xFF040406);
  static const bgElevated = Color(0xFF0E0F13);
  static const surface = Color(0x12FFFFFF); // cam dolgusu
  static const surfaceHi = Color(0x1EFFFFFF);
  static const stroke = Color(0x1AFFFFFF);
  static const strokeHi = Color(0x38FFFFFF);
  static const text = Color(0xFFF4F5FA);
  static const textDim = Color(0xB3F4F5FA);
  static const textFaint = Color(0x85F4F5FA); // siyah ve panel zemininde ≥ 4,5:1
  static const accent = Color(0xFFC9CFDA); // gümüş
  static const good = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFF87171);

  /// Kalan oran (0..1) için durum rengi.
  static Color forRemaining(double? fraction) {
    if (fraction == null) return textFaint;
    if (fraction <= 0.2) return bad;
    if (fraction <= 0.5) return warn;
    return good;
  }
}

abstract final class AppTheme {
  static ThemeData dark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.dark,
        surface: AppColors.bgElevated,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.text,
        displayColor: AppColors.text,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.stroke),
        ),
        textStyle: const TextStyle(color: AppColors.text, fontSize: 12),
        waitDuration: const Duration(milliseconds: 500),
      ),
    );
  }
}
