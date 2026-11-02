import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'prompt_counter.dart';
import 'usage_models.dart';
import 'usage_repository.dart';

/// Uygulama içinde açılan (görünür) web görünümlerine bağlanan kullanım kancaları.
///
/// SÖZLEŞME: lib/ui/viewer/web_pane.dart bunları çağırır.
abstract final class WebUsageHooks {
  /// JS tarafı `window.flutter_inappwebview.callHandler(handlerName, ...)` ile çağırır.
  static const handlerName = 'allaiUsage';

  // Yalnız istem gönderen istekler sayılır (POST). [Y] Uç noktalar gözlemle seçildi.
  static const _promptRequests = {
    'gemini': r'StreamGenerate',
    'deepseek': r'/api/v0/chat/(completion|regenerate)',
  };

  static final _pending = <String, Timer>{};

  /// Sayfaya eklenecek betikler (ör. gönderilen istemleri saymak).
  static List<UserScript> scriptsFor(String usageKey) {
    final pattern = _promptRequests[usageKey];
    if (pattern == null) return const [];
    return [
      UserScript(
        groupName: handlerName,
        source: promptCounterScript(pattern),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ];
  }

  /// JS'den gelen olay.
  static void onEvent(String usageKey, List<dynamic> args) {
    if (args.isEmpty || args.first != 'prompt' || !_promptRequests.containsKey(usageKey)) return;
    unawaited(PromptCounter.increment(usageKey)
        .then((_) => UsageRepository.instance.refresh(usageKey))
        .catchError((_) {}));
  }

  /// Sayfa yüklendi: oturum açılmış olabilir, bu servisin limitini tazele.
  static void onPageLoaded(String usageKey, InAppWebViewController controller, WebUri? url) {
    _pending[usageKey]?.cancel();
    _pending[usageKey] = Timer(const Duration(seconds: 3), () {
      _pending.remove(usageKey);
      final repo = UsageRepository.instance;
      final r = repo.reports[usageKey];
      // Az önce iyi veri geldiyse her sayfa yüklemesinde gizli sondayı yeniden açma.
      if (r != null &&
          r.status == UsageStatus.ok &&
          DateTime.now().difference(r.fetchedAt) < const Duration(minutes: 2)) {
        return;
      }
      unawaited(repo.refresh(usageKey));
    });
  }

  /// fetch ve XHR'ı sarar; [pattern]'e uyan POST isteğinde 'prompt' olayı yollar.
  /// Sayfayı asla bozmaz: her adım try/catch içinde, özgün çağrı her durumda yapılır.
  static String promptCounterScript(String pattern) => '''
(function () {
  if (window.__allaiUsageHook) return;
  window.__allaiUsageHook = true;
  var re = new RegExp(${jsonEncode(pattern)});
  function hit(url, method) {
    try {
      if (String(method || 'GET').toUpperCase() !== 'POST' || !re.test(String(url))) return;
      window.flutter_inappwebview.callHandler('$handlerName', 'prompt');
    } catch (e) {}
  }
  try {
    var origFetch = window.fetch;
    if (typeof origFetch === 'function') {
      window.fetch = function (input, init) {
        try {
          var req = typeof input === 'object' && input !== null ? input : null;
          hit(req && req.url ? req.url : input, (init && init.method) || (req && req.method));
        } catch (e) {}
        return origFetch.apply(window, arguments);
      };
    }
  } catch (e) {}
  try {
    var proto = XMLHttpRequest.prototype, origOpen = proto.open, origSend = proto.send;
    proto.open = function (method, url) {
      try { this.__allaiReq = [method, url]; } catch (e) {}
      return origOpen.apply(this, arguments);
    };
    proto.send = function () {
      try { if (this.__allaiReq) hit(this.__allaiReq[1], this.__allaiReq[0]); } catch (e) {}
      return origSend.apply(this, arguments);
    };
  } catch (e) {}
})();
''';
}
