import 'dart:io';

import 'package:flutter/services.dart';

/// Saydam başlık çubuğunda Flutter üst çubuğu fare olaylarını alır; pencereyi
/// sürükleme ve büyütme yerli tarafa (`allai/window`) devredilir.
class WindowBridge {
  WindowBridge._();

  static const _channel = MethodChannel('allai/window');

  /// Üst çubuğun boş alanında `onPanStart` içinde çağrılır; fare basılıyken pencereyi taşır.
  static Future<void> startDrag() => _invoke<void>('startDrag');

  /// Üst çubuğa çift tıklama: sistem tercihine göre doldur / büyüt / küçült / hiçbir şey.
  static Future<void> toggleZoom() => _invoke<void>('toggleZoom');

  static Future<bool> isFullScreen() async => await _invoke<bool>('isFullScreen') ?? false;

  static Future<T?> _invoke<T>(String method) async {
    if (!Platform.isMacOS) return null;
    try {
      return await _channel.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
