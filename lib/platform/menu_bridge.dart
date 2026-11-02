import 'dart:io';

import 'package:flutter/services.dart';

/// Yerel "Git" menüsü (`allai/menu`). Kısayollar WKWebView odaktayken de çalışır.
///
/// Eylemler: 'home' (⌘0), 'reload' (⌘R), 'back' (⌘[), 'forward' (⌘]),
/// 'open' (⌘1…⌘9; [index] 0 tabanlı, ⌘1 → 0, [setServiceNames] sırasıyla aynı).
class MenuBridge {
  MenuBridge._();

  static const _channel = MethodChannel('allai/menu');

  static void setHandler(void Function(String action, int? index)? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async => handler(call.method, call.arguments as int?),
    );
  }

  /// Menüdeki yapay zekâ adları (kart sırası). Listede olmayan sıra gizlenir, kısayolu kapanır.
  static Future<void> setServiceNames(List<String> names) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('setServiceNames', names);
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  /// Menü başlığı ve sabit öğelerin yerelleşmiş metinleri (anahtarlar: go, home, reload, back,
  /// forward, service; service içindeki `{n}` sıra numarasıdır).
  static Future<void> setLabels(Map<String, String> labels) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('setLabels', labels);
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }
}
