import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../models/ai_service.dart';
import '../../platform/web_config.dart';
import '../../usage/web_hooks.dart';
import 'loading_splash.dart';

/// Bir yapay zekânın gömülü web görünümü. Görüntüleyici kapansa da canlı kalır (oturum, sohbet yerinde).
class WebPane extends StatefulWidget {
  const WebPane({super.key, required this.service, this.onController});

  final AiService service;
  final ValueChanged<InAppWebViewController>? onController;

  /// Testlerde gerçek web görünümünün yerine çizilir (testte platform görünümü yok).
  @visibleForTesting
  static Widget Function(AiService service)? debugBody;

  @override
  State<WebPane> createState() => WebPaneState();
}

class WebPaneState extends State<WebPane> {
  InAppWebViewController? controller;
  double _progress = 0;
  bool _firstLoad = true;
  CreateWindowAction? _popup;

  void reload() => controller?.reload();
  void back() => controller?.goBack();
  void forward() => controller?.goForward();

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    if (WebPane.debugBody case final body?) return body(s);
    if (WebConfig.webViewMissing) return const _WebViewMissing();
    return Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: AppColors.bg)),
        Positioned.fill(
          child: InAppWebView(
            webViewEnvironment: WebConfig.environment,
            initialUrlRequest: URLRequest(url: WebUri(s.webUrl!)),
            initialSettings: WebConfig.settings(),
            initialUserScripts: UnmodifiableListView(WebUsageHooks.scriptsFor(s.usageKey)),
            onWebViewCreated: (c) {
              controller = c;
              c.addJavaScriptHandler(
                handlerName: WebUsageHooks.handlerName,
                callback: (args) => WebUsageHooks.onEvent(s.usageKey, args),
              );
              widget.onController?.call(c);
            },
            onProgressChanged: (c, p) {
              setState(() => _progress = p / 100);
              if (p >= 80 && _firstLoad) setState(() => _firstLoad = false);
            },
            onLoadStop: (c, url) {
              if (_firstLoad) setState(() => _firstLoad = false);
              WebUsageHooks.onPageLoaded(s.usageKey, c, url);
            },
            shouldOverrideUrlLoading: (c, nav) async {
              final scheme = nav.request.url?.scheme ?? 'https';
              const allowed = {'http', 'https', 'about', 'data', 'blob', 'javascript'};
              return allowed.contains(scheme) ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL;
            },
            // Google / Apple / Microsoft ile giriş açılır pencerede yürür; uygulama içinde gösteriyoruz.
            onCreateWindow: (c, action) async {
              setState(() => _popup = action);
              return true;
            },
            onPermissionRequest: (c, request) async => PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            ),
          ),
        ),
        // İnce yükleme çizgisi.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: AnimatedOpacity(
            opacity: _progress < 1 ? 1 : 0,
            duration: Motion.medium,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: Motion.fast,
                height: 2,
                width: MediaQuery.sizeOf(context).width * _progress,
                decoration: BoxDecoration(gradient: LinearGradient(colors: [s.color, s.accent])),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_firstLoad,
            child: AnimatedOpacity(
              opacity: _firstLoad ? 1 : 0,
              duration: Motion.slow,
              child: LoadingSplash(service: s, label: t('viewer.opening', {'name': s.name})),
            ),
          ),
        ),
        if (_popup != null)
          Positioned.fill(
            child: _PopupWindow(
              key: ValueKey(_popup!.windowId),
              action: _popup!,
              accent: s.color,
              onClose: () => setState(() => _popup = null),
            ),
          ),
      ],
    );
  }
}

/// window.open ile açılan pencere (giriş, bağlantı) — uygulamanın içinde, kart gibi.
class _PopupWindow extends StatefulWidget {
  const _PopupWindow({super.key, required this.action, required this.accent, required this.onClose});

  final CreateWindowAction action;
  final Color accent;
  final VoidCallback onClose;

  @override
  State<_PopupWindow> createState() => _PopupWindowState();
}

class _PopupWindowState extends State<_PopupWindow> {
  String _title = '';

  @override
  void initState() {
    super.initState();
    _title = widget.action.request.url?.host ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.slow,
      curve: Motion.springOut,
      builder: (context, v, child) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.45 * v.clamp(0, 1)),
        child: Center(
          child: Transform.scale(scale: 0.92 + 0.08 * v, child: Opacity(opacity: v.clamp(0, 1), child: child)),
        ),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth * 0.62).clamp(420.0, 760.0);
        final h = (c.maxHeight * 0.86).clamp(480.0, 900.0);
        return Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: AppColors.bgElevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.strokeHi),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 20))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    const Icon(Icons.lock_rounded, size: 14, color: AppColors.textFaint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppColors.textDim),
                      ),
                    ),
                    IconButton(
                      tooltip: t('viewer.close'),
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: AppColors.stroke),
              Expanded(
                child: InAppWebView(
                  webViewEnvironment: WebConfig.environment,
                  windowId: widget.action.windowId,
                  initialSettings: WebConfig.settings(),
                  onTitleChanged: (c, t) {
                    if (t != null && t.isNotEmpty) setState(() => _title = t);
                  },
                  onCloseWindow: (c) => widget.onClose(),
                  onCreateWindow: (c, a) async => false,
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// Windows'ta WebView2 Runtime yoksa web görünümü açılamaz; ne yapılacağı söylenir.
class _WebViewMissing extends StatelessWidget {
  const _WebViewMissing();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            t('core.webview2.missing'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: AppColors.textDim, height: 1.5),
          ),
        ),
      ),
    );
  }
}
