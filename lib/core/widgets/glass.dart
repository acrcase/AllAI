import 'package:flutter/material.dart';

import '../theme.dart';

/// Koyu cam yüzey: yarı saydam ton + ince kenar, içerik yuvarlak köşeye kırpılır.
///
/// Arka plan bulanıklığı (BackdropFilter) yok: bu makinede (Intel UHD 630) Impeller'da kareleri bozuyor,
/// Skia'da da her karede arkasını yeniden bulanıklaştırıyor (kullanım düğmesi ana ekranda hep açık;
/// panel açılırken bulanıklık yarıçapı her karede değişiyordu). Derin siyah zeminde bulanıklık zaten
/// seçilmiyor; okunurluğu daha opak ton sağlar.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 20,
    this.tint = AppColors.surface,
    this.border = AppColors.stroke,
    this.padding,
  });

  final Widget child;
  final double radius;
  final Color tint;
  final Color border;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: shape,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint,
          borderRadius: shape,
          border: Border.all(color: border),
        ),
        child: padding == null ? child : Padding(padding: padding!, child: child),
      ),
    );
  }
}
