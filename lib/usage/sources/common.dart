import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../usage_models.dart';
import '../usage_repository.dart';
import '../web_probe.dart';
import '../../l10n/l10n.dart';

/// Kaynakların ortak tabanı: [load] fırlatsa bile [fetch] hata raporu döner.
abstract class BaseSource extends UsageSource {
  Future<UsageReport> load();

  @override
  Future<UsageReport> fetch() async {
    try {
      return await load();
    } on TimeoutException {
      return report(UsageStatus.error, message: t('usage.err.timeout'));
    } on SocketException {
      return report(UsageStatus.error, message: t('usage.err.noConnection'));
    } on HandshakeException {
      return report(UsageStatus.error, message: t('usage.err.tls'));
    } on WebProbeException catch (e) {
      return report(UsageStatus.error, message: e.message);
    } catch (_) {
      return report(UsageStatus.error, message: t('usage.err.unexpected'));
    }
  }

  UsageReport report(
    UsageStatus status, {
    String? plan,
    String? message,
    String? source,
    List<UsageSection> sections = const [],
    String? actionLabel,
    bool connected = false,
  }) =>
      UsageReport(
        serviceId: serviceId,
        title: title,
        status: status,
        fetchedAt: DateTime.now(),
        plan: plan,
        message: message,
        source: source,
        sections: sections,
        actionLabel: actionLabel,
        connected: connected,
      );
}

/// Kaynakların ortak küçük HTTP yardımcıları. Başlıklar (belirteçler) hiçbir yere yazılmaz.

/// İstek atar, `(durum kodu, çözülmüş JSON ya da null)` döner. Ağ hatasında fırlatır.
Future<(int, Object?)> requestJson(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  Object? body,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.openUrl(method, url).timeout(timeout);
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {}
    return (res.statusCode, json);
  } finally {
    client.close(force: true);
  }
}

/// Komutu çalıştırır; çıkış kodu 0 ise kırpılmış stdout, değilse null.
Future<String?> runForOutput(String exe, List<String> args,
    {Duration timeout = const Duration(seconds: 10)}) async {
  try {
    final r = await Process.run(exe, args).timeout(timeout);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trim();
  } catch (_) {
    return null;
  }
}

/// Eşlem içinde güvenli gezinme: `dig(j, ['a', 'b'])`.
Object? dig(Object? j, List<Object> path) {
  var cur = j;
  for (final k in path) {
    if (k is String && cur is Map) {
      cur = cur[k];
    } else if (k is int && cur is List && k >= 0 && k < cur.length) {
      cur = cur[k];
    } else {
      return null;
    }
  }
  return cur;
}

double? asDouble(Object? v) => switch (v) {
      num n => n.toDouble(),
      String s => double.tryParse(s),
      _ => null,
    };

DateTime? asDate(Object? v) => switch (v) {
      String s => DateTime.tryParse(s),
      // Saniye cinsinden unix zamanı.
      num n when n > 0 => DateTime.fromMillisecondsSinceEpoch((n * 1000).round(), isUtc: true),
      _ => null,
    };

/// Kalan oran: kullanılan yüzdeden (0..100).
double? remainingFromUsedPercent(Object? usedPercent) {
  final p = asDouble(usedPercent);
  return p == null ? null : (1 - p / 100).clamp(0.0, 1.0);
}
