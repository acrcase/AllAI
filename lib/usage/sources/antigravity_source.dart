import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../usage_models.dart';
import 'common.dart';
import '../../l10n/l10n.dart';

/// Antigravity: kendi language server'ını penceresiz başlatır, `GetUserStatus` ile model
/// kotalarını sorar ve sunucuyu her durumda kapatır.
class AntigravitySource extends BaseSource {
  AntigravitySource({Future<Directory> Function()? workDir}) : _workDir = workDir ?? _defaultWorkDir;

  final Future<Directory> Function() _workDir;

  static const _app = '/Applications/Antigravity.app';
  static const _server = '$_app/Contents/Resources/bin/language_server';
  static String get _source => t('usage.ag.source');

  // Sunucuyu arka planda başlatır, stdin kapanınca (biz kapatınca ya da uygulama ölünce)
  // önce TERM, 3 sn içinde kapanmazsa KILL gönderir. Sunucu günlüğü tutulmaz.
  static const _wrapper = r'"$@" </dev/null >/dev/null 2>&1 & p=$!; read _; kill $p 2>/dev/null; '
      r'i=0; while kill -0 $p 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; '
      r'kill -9 $p 2>/dev/null; wait $p';

  static Future<Directory> _defaultWorkDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/antigravity-ls');

  @override
  String get serviceId => 'antigravity';

  @override
  String get title => 'Antigravity';

  @override
  Future<UsageReport> load() async {
    if (!Platform.isMacOS) return report(UsageStatus.unavailable, message: t('usage.macOnly'));
    if (!File(_server).existsSync()) {
      return report(UsageStatus.unavailable, message: t('usage.ag.notInstalled'));
    }
    final version = await runForOutput(
            '/usr/bin/defaults', ['read', '$_app/Contents/Info.plist', 'CFBundleShortVersionString']) ??
        '0';
    final dir = await _workDir();
    await dir.create(recursive: true);
    final port = await _freePort();
    final rnd = Random.secure();
    final csrf = [for (var i = 0; i < 16; i++) rnd.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

    final proc = await Process.start(
      '/bin/sh',
      [
        '-c', _wrapper, 'sh', _server, //
        '-standalone', '-headless',
        '-override_ide_name=antigravity', '-subclient_type=hub',
        '-override_ide_version=$version', '-override_user_agent_name=antigravity',
        '-http_server_port=$port', '-csrf_token=$csrf', '-app_data_dir=antigravity',
        '-api_server_url=https://generativelanguage.googleapis.com',
        '-cloud_code_endpoint=https://daily-cloudcode-pa.googleapis.com',
        '-use_ls_chrome_devtools_mcp=false',
      ],
      workingDirectory: dir.path,
    );
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    try {
      if (!await _waitHealthy(port, proc)) {
        return report(UsageStatus.error, message: t('usage.ag.serverFail'), source: _source);
      }
      final (code, body) = await requestJson(
        'POST',
        Uri.parse('http://127.0.0.1:$port/exa.language_server_pb.LanguageServerService/GetUserStatus'),
        headers: {'x-codeium-csrf-token': csrf},
        body: {
          'metadata': {
            'ideName': 'antigravity',
            'extensionName': 'antigravity',
            'ideVersion': version,
            'locale': 'en',
          },
        },
        timeout: const Duration(seconds: 10),
      );
      return parseUserStatus(code, body);
    } finally {
      await _stop(proc);
    }
  }

  /// `GetUserStatus` yanıtını rapora çevirir.
  UsageReport parseUserStatus(int code, Object? body) {
    if (code != 200) {
      final msg = '${dig(body, ['message']) ?? ''}'.toLowerCase();
      if (msg.contains('auth') || msg.contains('login') || msg.contains('sign in')) {
        return report(UsageStatus.needsLogin,
            message: t('usage.ag.login'), source: _source);
      }
      return report(UsageStatus.error, message: t('usage.err.http', {'name': 'Antigravity', 'code': code}), source: _source);
    }
    final status = dig(body, ['userStatus']);
    if (status is! Map || status.isEmpty) {
      return report(UsageStatus.needsLogin,
          message: t('usage.ag.login'), source: _source);
    }
    final plan = (dig(status, ['userTier', 'name']) ?? dig(status, ['planStatus', 'planInfo', 'planName']))
        as String?;
    final sections =
        antigravitySections(dig(status, ['cascadeModelConfigData', 'clientModelConfigs']));
    if (sections.isEmpty) {
      return report(UsageStatus.noData, plan: plan, message: t('usage.ag.noQuota'), source: _source);
    }
    return report(UsageStatus.ok, plan: plan, sections: sections, source: _source);
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static Future<bool> _waitHealthy(int port, Process proc) async {
    var exited = false;
    unawaited(proc.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    final url = Uri.parse('http://127.0.0.1:$port/healthz');
    while (!exited && DateTime.now().isBefore(deadline)) {
      try {
        final (code, body) = await requestJson('GET', url, timeout: const Duration(seconds: 2));
        if (code == 200 && dig(body, ['status']) == 'ok') return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  static Future<void> _stop(Process proc) async {
    try {
      await proc.stdin.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await proc.exitCode.timeout(const Duration(seconds: 6), onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
  }
}

/// Modelleri aileye göre bölümler. Aynı modelin modları (Low/Medium/High) aynı kotayı
/// paylaşıyorsa tek çubukta birleşir.
List<UsageSection> antigravitySections(Object? configs) {
  if (configs is! List) return const [];
  final groups = <String, List<({String label, String? mode, double? remaining, DateTime? resetsAt})>>{};
  for (final c in configs) {
    final label = dig(c, ['label']);
    final quota = dig(c, ['quotaInfo']);
    if (label is! String || quota is! Map) continue;
    final resetsAt = asDate(quota['resetTime']);
    // remainingFraction yok ama sıfırlanma zamanı varsa kota bitmiştir.
    final remaining = asDouble(quota['remainingFraction']) ?? (resetsAt != null ? 0.0 : null);
    final m = RegExp(r'^(.*?)\s*\(([^)]*)\)$').firstMatch(label);
    groups.putIfAbsent(m?[1] ?? label, () => []).add(
        (label: label, mode: m?[2], remaining: remaining, resetsAt: resetsAt));
  }

  final gemini = t('usage.ag.gemini'), claude = t('usage.ag.claude'), other = t('usage.ag.other');
  final families = <String, List<UsageMeter>>{gemini: [], claude: [], other: []};
  for (final MapEntry(key: base, value: vs) in groups.entries) {
    final family = base.startsWith('Gemini')
        ? gemini
        : base.startsWith('Claude')
            ? claude
            : other;
    final first = vs.first;
    final shared = vs.length > 1 &&
        vs.every((v) => v.remaining == first.remaining && v.resetsAt == first.resetsAt);
    if (shared) {
      final modes = [for (final v in vs) ?v.mode]..sort(_byMode);
      families[family]!.add(UsageMeter(
        label: base,
        remaining: first.remaining,
        resetsAt: first.resetsAt,
        detail: t('usage.ag.shared', {'modes': modes.join(' · ')}),
      ));
    } else {
      for (final v in vs) {
        families[family]!.add(UsageMeter(label: v.label, remaining: v.remaining, resetsAt: v.resetsAt));
      }
    }
  }
  return [
    for (final MapEntry(key: title, value: meters) in families.entries)
      if (meters.isNotEmpty)
        UsageSection(title: title, meters: meters..sort((a, b) => a.label.compareTo(b.label))),
  ];
}

int _byMode(String a, String b) {
  const order = ['Low', 'Medium', 'High'];
  int rank(String m) => order.contains(m) ? order.indexOf(m) : order.length;
  final r = rank(a).compareTo(rank(b));
  return r != 0 ? r : a.compareTo(b);
}
