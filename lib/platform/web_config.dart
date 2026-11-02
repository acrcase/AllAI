import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Bütün web görünümlerinin (görünür ve gizli) ortak ayarı.
///
/// Google girişi gömülü tarayıcıyı kullanıcı aracısından tanıyıp reddeder; bu yüzden
/// macOS'ta Safari'nin, Android'de Chrome'un kimliğiyle görünürüz.
abstract final class WebConfig {
  static String _safariVersion = '18.6';

  /// Yalnız Windows: WebView2 ortamı. Veri klasörü uygulama verisinin altında (varsayılanı
  /// `allai.exe.WebView2`, exe'nin yanındadır: Program Files'a kurulumda yazılamaz, sıfırlamada silinemez).
  /// null: Windows dışı ya da WebView2 Runtime yok ([webViewMissing]).
  static WebViewEnvironment? environment;

  /// Windows'ta WebView2 Runtime kurulu değil ya da ortam kurulamadı.
  static bool webViewMissing = false;

  /// Windows'ta WebView2 veri klasörü (sıfırlama bunu da siler).
  static Future<String> windowsWebViewDir() async =>
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}WebView2';

  /// Uygulama açılışında bir kez çağrılır.
  static Future<void> init() async {
    if (Platform.isWindows) {
      try {
        if (await WebViewEnvironment.getAvailableVersion() == null) {
          webViewMissing = true;
          return;
        }
        environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: await windowsWebViewDir()),
        );
      } catch (_) {
        webViewMissing = true;
      }
      return;
    }
    if (!Platform.isMacOS) return;
    try {
      final r = await Process.run('defaults', [
        'read',
        '/Applications/Safari.app/Contents/Info.plist',
        'CFBundleShortVersionString',
      ]);
      final v = (r.stdout as String).trim();
      if (r.exitCode == 0 && RegExp(r'^\d+(\.\d+)*$').hasMatch(v)) _safariVersion = v;
    } catch (_) {}
  }

  /// null: Windows'ta WebView2'nin kendi (Edge/Chromium) kimliği kalır; Google girişi onu reddetmez.
  static String? get userAgent {
    if (Platform.isWindows) return null;
    if (Platform.isMacOS) {
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
          '(KHTML, like Gecko) Version/$_safariVersion Safari/605.1.15';
    }
    return 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
  }

  static InAppWebViewSettings settings() => InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        // Sürümde Web Denetçisi kapalı: oturum çerezleri Safari'den görülemesin.
        isInspectable: kDebugMode,
        transparentBackground: true,
        allowsBackForwardNavigationGestures: true,
        useShouldOverrideUrlLoading: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
      );
}
