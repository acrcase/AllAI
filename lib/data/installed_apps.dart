import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import '../models/ai_service.dart';
import 'site_icon.dart';

/// Bilgisayarda kurulu, karta çevrilebilen bir uygulama.
/// macOS: [id] paket kimliği, [path] `.app` klasörü. Windows: [id] ve [path] aynı, `.exe` yolu.
class InstalledApp {
  const InstalledApp({
    required this.name,
    required this.id,
    required this.path,
    this.windows = false,
  });

  final String name;
  final String id;
  final String path;
  final bool windows;

  /// Ana ekran kartı. Kimlik `app-<id>`; Windows'ta büyük/küçük harf farkı aynı programı bölmesin.
  AiService toService({String? icon, Color? color, Color? accent}) {
    final hue = (name.hashCode % 360).toDouble();
    final key = windows ? id.toLowerCase() : id;
    return AiService(
      id: 'app-$key',
      name: name,
      subtitle: AiService.appSubtitle,
      icon: icon,
      color: color ?? HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor(),
      accent:
          accent ?? HSLColor.fromAHSL(1, (hue + 40) % 360, 0.8, 0.72).toColor(),
      macBundleId: windows ? null : id,
      appPath: windows ? path : null,
      mode: OpenMode.app,
      // Bilinen bir limit kaynağı yok: UsageRepository.setOrder tanımadığı anahtarı eler.
      usageKey: 'app-$key',
      custom: true,
    );
  }
}

/// Bir uygulamanın simgesi (yerel PNG) ve ondan çıkarılan renkler.
typedef AppIcon = ({String path, Color color, Color accent});

// ---------------------------------------------------------------------------------------------
// Saf ayrıştırıcılar ve komut kurucular (platformdan bağımsız, birim testli).
// ---------------------------------------------------------------------------------------------

/// XML `Info.plist`in en üst sözlüğündeki dize ve mantıksal değerler (`true`/`false` metin olarak).
/// İç içe sözlük ve diziler atlanır.
Map<String, String> parsePlistTopLevel(String xml) {
  final token = RegExp(
    r'<key>(.*?)</key>|<string>(.*?)</string>|<(dict|array)>|</(dict|array)>|<(true|false)\s*/>'
    r'|<(?:string|dict|array)\s*/>|<(integer|real|date)>.*?</\6>|<data>.*?</data>',
    dotAll: true,
  );
  final out = <String, String>{};
  var depth = 0;
  String? key;
  for (final m in token.allMatches(xml)) {
    if (m.group(1) != null) {
      if (depth == 1) key = _unescape(m.group(1)!);
    } else if (m.group(3) != null) {
      depth++;
      if (depth == 2) key = null;
    } else if (m.group(4) != null) {
      depth--;
    } else if (depth == 1 && key != null) {
      final v = m.group(2) ?? m.group(5);
      if (v != null) out[key] = _unescape(v);
      key = null;
    }
  }
  return out;
}

String _unescape(String s) => s
    .replaceAllMapped(
      RegExp(r'&#(x?)([0-9a-fA-F]+);'),
      (m) =>
          String.fromCharCode(int.parse(m[2]!, radix: m[1] == 'x' ? 16 : 10)),
    )
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// Ayrıştırılmış Info.plist'ten kart adayı. Paket kimliği yoksa ya da arka plan (pencere açmayan)
/// uygulamasıysa null. Ad: CFBundleDisplayName, CFBundleName, yoksa klasör adı.
InstalledApp? macAppFromPlist(Map<String, String> info, String appPath) {
  final id = info['CFBundleIdentifier'];
  if (id == null || id.isEmpty) return null;
  if (info['LSBackgroundOnly'] == 'true' || info['LSUIElement'] == 'true') {
    return null;
  }
  final folder = appPath.split('/').where((e) => e.isNotEmpty).last;
  final name = [
    info['CFBundleDisplayName'],
    info['CFBundleName'],
    folder.replaceAll(RegExp(r'\.app$'), ''),
  ].firstWhere((e) => e != null && e.trim().isNotEmpty)!;
  return InstalledApp(name: name.trim(), id: id, path: appPath);
}

/// `Contents/Resources` içindeki simge dosyası adı (uzantısız yazılmış olabilir); yoksa null.
String? macIconFileName(Map<String, String> info) {
  final f = info['CFBundleIconFile'];
  if (f == null || f.isEmpty) return null;
  return f.toLowerCase().endsWith('.icns') ? f : '$f.icns';
}

/// PowerShell çıktısı (`[{name,target}]` ya da tek `{name,target}`) -> kurulu programlar.
/// Yalnız `.exe` hedefler; kaldırıcılar elenir; aynı hedef bir kez; ada göre sıralı.
List<InstalledApp> parseShortcutJson(String json) {
  final text = json.trim();
  if (text.isEmpty) return const [];
  final Object? data;
  try {
    data = jsonDecode(text.startsWith('﻿') ? text.substring(1) : text);
  } catch (_) {
    return const [];
  }
  final seen = <String>{};
  final out = <InstalledApp>[];
  for (final e in data is List ? data : [data]) {
    if (e is! Map) continue;
    final name = (e['name'] as String?)?.trim() ?? '';
    final target = (e['target'] as String?)?.trim() ?? '';
    final file = target.split(RegExp(r'[\\/]')).last.toLowerCase();
    if (name.isEmpty || !file.endsWith('.exe')) continue;
    if (RegExp(
      r'uninstall|(^|\s)unins\d*\.exe$',
      caseSensitive: false,
    ).hasMatch('$name $file')) {
      continue;
    }
    if (seen.add(target.toLowerCase())) {
      out.add(
        InstalledApp(name: name, id: target, path: target, windows: true),
      );
    }
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// PowerShell tek tırnaklı dize değişmezi.
String psQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// `powershell -EncodedCommand` değeri: UTF-16LE base64 (tırnak/kaçış sorunu yok).
String psEncode(String script) {
  final bytes = <int>[
    for (final u in script.codeUnits) ...[u & 0xFF, u >> 8],
  ];
  return base64Encode(bytes);
}

const _psUtf8 = '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;';

/// Başlat Menüsü kısayollarını (.lnk) tarar, hedeflerini çözer.
String windowsScanScript() =>
    '''
$_psUtf8
\$sh = New-Object -ComObject WScript.Shell
\$roots = @("\$env:ProgramData\\Microsoft\\Windows\\Start Menu\\Programs", "\$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs")
\$list = @(Get-ChildItem -LiteralPath \$roots -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
  \$t = \$sh.CreateShortcut(\$_.FullName).TargetPath
  if (\$t) { [pscustomobject]@{ name = \$_.BaseName; target = \$t } }
})
ConvertTo-Json -InputObject \$list -Compress
''';

/// .exe ya da .lnk seçtiren pencere; seçilen programı `[{name,target}]` yazar, vazgeçilirse 1 ile çıkar.
String windowsPickScript(String title) =>
    '''
$_psUtf8
Add-Type -AssemblyName System.Windows.Forms
\$d = New-Object System.Windows.Forms.OpenFileDialog
\$d.Title = ${psQuote(title)}
\$d.Filter = '*.exe;*.lnk|*.exe;*.lnk'
if (\$d.ShowDialog() -ne 'OK') { exit 1 }
\$p = \$d.FileName
if (\$p -like '*.lnk') {
  \$t = (New-Object -ComObject WScript.Shell).CreateShortcut(\$p).TargetPath
  \$n = [System.IO.Path]::GetFileNameWithoutExtension(\$p)
} else {
  \$t = \$p
  \$n = (Get-Item -LiteralPath \$p).VersionInfo.ProductName
  if (-not \$n) { \$n = [System.IO.Path]::GetFileNameWithoutExtension(\$p) }
}
ConvertTo-Json -InputObject @([pscustomobject]@{ name = \$n; target = \$t }) -Compress
''';

/// Programın ilişkili simgesini PNG olarak yazar.
String windowsIconScript(String exe, String outPng) =>
    '''
Add-Type -AssemblyName System.Drawing
\$i = [System.Drawing.Icon]::ExtractAssociatedIcon(${psQuote(exe)})
\$i.ToBitmap().Save(${psQuote(outPng)}, [System.Drawing.Imaging.ImageFormat]::Png)
''';

List<String> powershellArgs(String script) => [
  '-NoProfile',
  '-NonInteractive',
  '-STA',
  '-ExecutionPolicy',
  'Bypass',
  '-EncodedCommand',
  psEncode(script),
];

/// `osascript` bağımsız değişkenleri: istem metni kabuğa değil argv'ye gider.
const macPickArgs = [
  '-e',
  'on run argv',
  '-e',
  'POSIX path of (choose file of type {"app"} with prompt (item 1 of argv) default location (path to applications folder))',
  '-e',
  'end run',
];

// ---------------------------------------------------------------------------------------------
// Platform katmanı
// ---------------------------------------------------------------------------------------------

/// Kurulu uygulamaları bulur, simge üretir, seçtirir, açar (macOS ve Windows). Testte sahtesi takılır.
class InstalledApps {
  InstalledApps();
  static final instance = InstalledApps();

  /// Bu platformda "Uygulama ekle" sunulur mu.
  bool get supported => Platform.isMacOS || Platform.isWindows;

  final _icons = <String, Future<AppIcon?>>{};

  Future<List<InstalledApp>> scan() async {
    try {
      return Platform.isMacOS ? await _scanMac() : await _scanWindows();
    } catch (_) {
      return const [];
    }
  }

  /// Dosya seçtirir. Vazgeçilirse ya da seçilen uygulama anlaşılamazsa null.
  Future<InstalledApp?> pick(String prompt) async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('/usr/bin/osascript', [
          ...macPickArgs,
          prompt,
        ]);
        if (r.exitCode != 0) return null;
        final path = (r.stdout as String).trim().replaceAll(RegExp(r'/+$'), '');
        return path.isEmpty ? null : await _macApp(path);
      }
      if (Platform.isWindows) {
        final r = await Process.run(
          'powershell.exe',
          powershellArgs(windowsPickScript(prompt)),
          stdoutEncoding: utf8,
        );
        return r.exitCode != 0
            ? null
            : parseShortcutJson(r.stdout as String).firstOrNull;
      }
    } catch (_) {}
    return null;
  }

  /// Windows programını kendi penceresinde açar. Yol yoksa ya da başlatılamazsa false.
  Future<bool> launch(String path) async {
    try {
      if (!await File(path).exists()) return false;
      await Process.start(
        path,
        const [],
        workingDirectory: File(path).parent.path,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Simge PNG'si ve renkleri; uygulama başına bir kez üretilir. Üretilemezse null (baş harfli rozet).
  Future<AppIcon?> icon(InstalledApp app) =>
      _icons.putIfAbsent(app.id, () => _makeIcon(app));

  // --- macOS

  Future<List<InstalledApp>> _scanMac() async {
    final home = Platform.environment['HOME'];
    final self = _ownBundle();
    final bundles = <String>[];
    for (final root in [
      '/Applications',
      '/System/Applications',
      if (home != null) '$home/Applications',
    ]) {
      try {
        await for (final e in Directory(root).list(followLinks: false)) {
          if (e.path.endsWith('.app')) {
            bundles.add(e.path);
          } else if (e is Directory) {
            // Utilities, Setapp gibi bir alt klasör.
            try {
              bundles.addAll([
                await for (final c in e.list(followLinks: false))
                  if (c.path.endsWith('.app')) c.path,
              ]);
            } catch (_) {}
          }
        }
      } catch (_) {} // klasör yok
    }
    final out = <InstalledApp>[];
    final seen = <String>{};
    for (var i = 0; i < bundles.length; i += 8) {
      final chunk = bundles.skip(i).take(8).where((p) => p != self);
      for (final a in await Future.wait(chunk.map(_macApp))) {
        if (a != null && seen.add(a.id)) out.add(a);
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Çalışan AllAI'nin kendi `.app` klasörü: kendini eklemesin.
  String? _ownBundle() {
    final exe = Platform.resolvedExecutable;
    final i = exe.indexOf('.app/');
    return i < 0 ? null : exe.substring(0, i + 4);
  }

  Future<Map<String, String>?> _macInfo(String appPath) async {
    try {
      final file = File('$appPath/Contents/Info.plist');
      List<int> bytes = await file.readAsBytes();
      if (bytes.length > 6 && String.fromCharCodes(bytes.take(6)) == 'bplist') {
        final r = await Process.run('/usr/bin/plutil', [
          '-convert',
          'xml1',
          '-o',
          '-',
          '--',
          file.path,
        ], stdoutEncoding: null);
        if (r.exitCode != 0) return null;
        bytes = r.stdout as List<int>;
      }
      return parsePlistTopLevel(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  Future<InstalledApp?> _macApp(String appPath) async {
    final info = await _macInfo(appPath);
    return info == null ? null : macAppFromPlist(info, appPath);
  }

  // --- Windows

  Future<List<InstalledApp>> _scanWindows() async {
    final r = await Process.run(
      'powershell.exe',
      powershellArgs(windowsScanScript()),
      stdoutEncoding: utf8,
    );
    final self = Platform.resolvedExecutable.toLowerCase();
    return [
      for (final a in parseShortcutJson(r.stdout as String))
        if (a.path.toLowerCase() != self) a,
    ];
  }

  // --- simge

  Future<AppIcon?> _makeIcon(InstalledApp app) async {
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/icons',
      );
      await dir.create(recursive: true);
      final safe = app.id.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '_');
      final out = File(
        '${dir.path}/app-${safe.length > 80 ? safe.substring(safe.length - 80) : safe}-${app.id.hashCode.toRadixString(16)}.png',
      );
      if (!await out.exists() || await out.length() == 0) {
        if (app.windows) {
          await Process.run(
            'powershell.exe',
            powershellArgs(windowsIconScript(app.path, out.path)),
          );
        } else {
          final name = macIconFileName(await _macInfo(app.path) ?? const {});
          if (name == null) return null;
          final src = File('${app.path}/Contents/Resources/$name');
          if (!await src.exists()) return null;
          await Process.run('/usr/bin/sips', [
            '-s',
            'format',
            'png',
            '--resampleWidth',
            '128',
            src.path,
            '--out',
            out.path,
          ]);
        }
      }
      if (!await out.exists() || await out.length() == 0) return null;
      final codec = await ui.instantiateImageCodec(
        await out.readAsBytes(),
        targetWidth: 64,
      );
      final image = (await codec.getNextFrame()).image;
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) return null;
      final (color, accent) = SiteIcon.brand(raw.buffer.asUint8List());
      return (path: out.path, color: color, accent: accent);
    } catch (_) {
      return null;
    }
  }
}
