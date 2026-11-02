import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/web_config.dart';
import '../usage/usage_repository.dart';

/// AllAI'nin bu bilgisayarda bıraktığı her şeyi siler (ayarlar, oturumlar, önbellek, ikinci hesap
/// profilleri) ve uygulamayı kapatır. Diğer uygulamalara dokunmaz.
Future<void> wipeAllDataAndQuit() async {
  try {
    UsageRepository.instance
        .dispose(); // arka plan yenileme önbelleği yeniden yazmasın
  } catch (_) {}
  try {
    await (await SharedPreferences.getInstance()).clear();
  } catch (_) {}
  try {
    await CookieManager.instance(webViewEnvironment: WebConfig.environment)
        .deleteAllCookies();
  } catch (_) {}
  try {
    await InAppWebViewController.clearAllCache();
  } catch (_) {}
  try {
    final support = await getApplicationSupportDirectory();
    final id = support.path.split('/').last; // paket kimliği
    final home = Platform.environment['HOME'];
    final dirs = <String>[
      support.path,
      (await getApplicationCacheDirectory()).path,
      if (home != null && Platform.isMacOS) ...[
        '$home/Library/WebKit/$id',
        '$home/Library/HTTPStorages/$id',
        '$home/Library/Saved Application State/$id.savedState',
        '$home/Library/Caches/$id',
      ],
    ];
    for (final d in dirs) {
      try {
        final dir = Directory(d);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
    // Windows: WebView2 süreçleri çıkana kadar veri klasörünü kilitler (WebView2 klasörü support içinde);
    // uygulama kapandıktan sonra ayrık bir PowerShell kalanı siler.
    if (Platform.isWindows) await _deleteAfterExit(dirs);
  } catch (_) {}
  // Normal çıkış: AllAI'nin açtığı uygulamalar da kapanır. Takılırsa zorla çık.
  unawaited(Future<void>.delayed(const Duration(seconds: 2), () => exit(0)));
  await SystemNavigator.pop();
}

Future<void> _deleteAfterExit(List<String> dirs) async {
  try {
    final paths = [for (final d in dirs) "'${d.replaceAll("'", "''")}'"]
        .join(',');
    await Process.start('powershell', [
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-Command',
      'Start-Sleep -Seconds 4; Remove-Item -Recurse -Force -LiteralPath $paths -ErrorAction SilentlyContinue',
    ], mode: ProcessStartMode.detached);
  } catch (_) {}
}
