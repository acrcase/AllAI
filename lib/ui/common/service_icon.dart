import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/ai_service.dart';

/// Yapay zekânın simgesi; varlığı yoksa marka renginde baş harf rozeti.
/// Web sürümü olan kartlarda sağ altta küre rozeti.
/// Varlık yolu ya da internetten indirilmiş yerel dosya (mutlak yol).
ImageProvider iconImage(String path) => isLocalIconFile(path) ? FileImage(File(path)) : AssetImage(path) as ImageProvider;

/// Mutlak dosya yolu mu (macOS '/…', Windows 'C:\…' ya da 'C:/…'); varlık yolları 'assets/…' ile başlar.
bool isLocalIconFile(String path) => path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

class ServiceIcon extends StatelessWidget {
  const ServiceIcon(this.service, {super.key, this.size = 64, this.showBadge = true});

  final AiService service;
  final double size;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final path = service.icon;
    final Widget icon;
    if (path == null) {
      icon = _Monogram(service: service, size: size);
    } else if (isLocalIconFile(path)) {
      // Sitenin kendi simgesi kare ve çoğu kez köşesiz: uygulama simgesi gibi yuvarlatılıp boşluk bırakılır.
      icon = Padding(
        padding: EdgeInsets.all(size * 0.09),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.2),
          child: Image(
            image: iconImage(path),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) => _Monogram(service: service, size: size),
          ),
        ),
      );
    } else {
      icon = Image.asset(path, width: size, height: size, filterQuality: FilterQuality.medium);
    }
    if (!showBadge || !service.isWebBadge) return SizedBox.square(dimension: size, child: icon);
    final b = size * 0.36;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: icon),
          Positioned(
            right: size * 0.02,
            bottom: size * 0.04,
            child: Container(
              width: b,
              height: b,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.bgElevated,
                border: Border.all(color: service.color, width: size * 0.025),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
              ),
              child: Icon(Icons.language_rounded, size: b * 0.62, color: AppColors.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram({required this.service, required this.size});

  final AiService service;
  final double size;

  @override
  Widget build(BuildContext context) {
    final inset = size * 0.09; // macOS simgeleriyle aynı iç boşluk
    return Padding(
      padding: EdgeInsets.all(inset),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.2),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [service.color, Color.lerp(service.color, service.accent, 0.55)!],
          ),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: size * 0.08, offset: Offset(0, size * 0.03))],
        ),
        child: Center(
          child: Text(
            service.name.characters.first.toUpperCase(),
            style: TextStyle(
              fontSize: size * 0.42,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
