import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../platform/web_config.dart';
import '../l10n/l10n.dart';

/// Kaynakların sonda çağrısı (testte sahtesi takılır).
typedef WebProbeRunner = Future<Object?> Function(String url, String functionBody);

class WebProbeException implements Exception {
  const WebProbeException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Gizli web görünümü: [run] kök sayfayı açar, sayfa bağlamında async JS gövdesini çalıştırır
/// ve döndürdüğü JSON metnini çözer.
///
/// Gizli ve görünür web görünümleri varsayılan veri deposunu (çerezler, cf_clearance) paylaşır;
/// fetch sayfa bağlamında yapıldığı için oturum çerezleri taşınır. Belirteçler sayfadan çıkmaz.
/// Tek seferde bir sonda: `UsageRepository` web kaynaklarını sıraya koyar.
abstract final class WebProbe {
  static bool get supported =>
      Platform.isMacOS ||
      Platform.isAndroid ||
      Platform.isIOS ||
      (Platform.isWindows && WebConfig.environment != null);

  static Future<Object?> run(String url, String functionBody) async {
    final loaded = Completer<void>();
    final view = HeadlessInAppWebView(
      webViewEnvironment: WebConfig.environment,
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: WebConfig.settings(),
      onLoadStop: (_, _) {
        if (!loaded.isCompleted) loaded.complete();
      },
      onReceivedError: (_, request, error) {
        // Yönlendirmede iptal edilen yüklemeler hata değildir.
        if (error.type == WebResourceErrorType.CANCELLED) return;
        if (request.isForMainFrame != false && !loaded.isCompleted) {
          loaded.completeError(WebProbeException(t('usage.web.openFail')));
        }
      },
    );
    try {
      await view.run();
      await loaded.future.timeout(const Duration(seconds: 12),
          onTimeout: () => throw WebProbeException(t('usage.web.loadTimeout')));
      final controller = view.webViewController;
      if (controller == null) throw WebProbeException(t('usage.web.hiddenFail'));
      final r = await controller
          .callAsyncJavaScript(functionBody: functionBody)
          .timeout(const Duration(seconds: 8));
      if (r == null || r.error != null) throw WebProbeException(t('usage.web.scriptFail'));
      final v = r.value;
      return v is String ? jsonDecode(v) : v;
    } finally {
      try {
        await view.dispose();
      } catch (_) {}
    }
  }
}
