import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart';

import 'sources/common.dart' show runForOutput;

/// Çözülmüş tek bir çerez. [value] düz metindir; hiçbir yere yazılmaz, yalnız bellekte.
class ChromiumCookie {
  const ChromiumCookie(this.host, this.name, this.value);

  final String host;
  final String name;
  final String value;
}

/// sqlite3 gibi komutları çalıştırır (testte sahtesi takılır; gerçek DB okunmaz).
typedef ProcessRunner = Future<String?> Function(String exe, List<String> args);

/// "Safe Storage" parolasını okur. Üretimde AllAI'nin KENDİ imzalı süreci (native `allai/keychain`
/// kanalı, Security.framework) kullanılır — `/usr/bin/security` aracı DEĞİL. Testte sahtesi takılır.
typedef SafeStoragePasswordReader = Future<String?> Function(String service);

const _keychainChannel = MethodChannel('allai/keychain');

/// Varsayılan okuyucu: native kanal. Yalnız kullanıcı onayından sonra çağrılır; parola loglanmaz.
Future<String?> keychainSafeStoragePassword(String service) async {
  try {
    final pw = await _keychainChannel.invokeMethod<String>('safeStoragePassword', {'service': service});
    return (pw == null || pw.isEmpty) ? null : pw;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Chromium tabanlı bir uygulamanın (Claude masaüstü, Chrome) çerez deposunu SALT OKUNUR açar
/// ve "Safe Storage" anahtarlık parolasından türetilen anahtarla değerleri çözer.
///
/// KURALLAR: DB kopyalanmaz (`immutable=1` salt okunur URI). Parola, türetilen anahtar ve çerez
/// değerleri diske yazılmaz, loglanmaz, alt süreç argümanına girmez; yalnız bu nesnenin ömrü boyunca
/// bellekte kalır. Türetilen anahtar oturum boyu önbelleğe alınır: anahtarlık yalnız BİR kez okunur.
class ChromiumCookieStore {
  ChromiumCookieStore({
    required this.cookiesDbPath,
    required this.safeStorageService,
    ProcessRunner runProcess = runForOutput,
    SafeStoragePasswordReader passwordReader = keychainSafeStoragePassword,
  })  : _run = runProcess,
        _password = passwordReader;

  /// Örn. `~/Library/Application Support/Claude/Cookies`.
  final String cookiesDbPath;

  /// Anahtarlık genel parola adı, örn. `Claude Safe Storage` / `Chrome Safe Storage`.
  final String safeStorageService;

  final ProcessRunner _run;
  final SafeStoragePasswordReader _password;

  // Türetilen AES anahtarı: oturum boyu bellekte. forgetKey() ile (bağlantıyı kesince) silinir.
  Uint8List? _key;

  // Her forgetKey'de artar: süren bir okuma, kendi başladığı nesli değişmiş görürse sonucu atar.
  int _epoch = 0;

  /// Anahtarı önce SIFIRLAR (bellekteki baytları temizler), sonra referansı bırakır, sonra nesli
  /// artırır ki süren okuma iptal olsun. "Bağlantıyı kes" yarışına karşı.
  void forgetKey() {
    final old = _key;
    if (old != null) old.fillRange(0, old.length, 0);
    _key = null;
    _epoch++;
  }

  // SQLite salt okunur URI'si: yol yüzde kodlanır (profil adıyla gelebilecek ?/#/boşluk kaçışlarına karşı).
  String get _uri =>
      Uri(scheme: 'file', path: cookiesDbPath, queryParameters: {'immutable': '1'}).toString();

  /// [hosts] ve [names] (tam eşleşme) ile eşleşen çerezleri çözer. DB yoksa, parola okunamazsa ya da
  /// sqlite3 başarısızsa null. Anahtarlık yalnız ilk çağrıda okunur; sonrakiler önbellekteki anahtarı
  /// kullanır ama çerez DB'sini her seferinde yeniden okur. Okuma sırasında bağlantı kesilirse null.
  Future<List<ChromiumCookie>?> read({
    required List<String> hosts,
    required List<String> names,
  }) async {
    if (!File(cookiesDbPath).existsSync()) return null;
    final epoch = _epoch;
    if (_key == null) {
      final password = await _password(safeStorageService);
      if (epoch != _epoch) return null; // arada bağlantı kesildi: sonucu at
      if (password == null || password.isEmpty) return null;
      final derived = deriveChromiumKey(password);
      if (epoch != _epoch) {
        derived.fillRange(0, derived.length, 0);
        return null;
      }
      _key = derived;
    }
    final key = _key!;
    final version = await _metaVersion();
    final hostList = _sqlList(hosts);
    final nameList = _sqlList(names);
    // \x1e alan, \x1f satır ayırıcı: çerez değerlerinde (base64/JWT) geçmez. Değer SELECT'te yok.
    final out = await _run('/usr/bin/sqlite3', [
      '-readonly', '-separator', '\x1e', '-newline', '\x1f', _uri,
      'SELECT host_key, name, value, hex(encrypted_value) FROM cookies '
          'WHERE host_key IN ($hostList) AND name IN ($nameList);',
    ]);
    if (out == null || epoch != _epoch) return null;
    final cookies = <ChromiumCookie>[];
    for (final row in out.split('\x1f')) {
      if (row.isEmpty) continue;
      final f = row.split('\x1e');
      if (f.length < 4) continue;
      final (host, name, plain, encHex) = (f[0], f[1], f[2], f[3]);
      final value = encHex.isNotEmpty
          ? decryptChromiumCookie(_fromHex(encHex), key, metaVersion: version)
          : (plain.isNotEmpty ? plain : null);
      if (value != null && value.isNotEmpty) cookies.add(ChromiumCookie(host, name, value));
    }
    return cookies;
  }

  Future<int> _metaVersion() async {
    final out = await _run(
        '/usr/bin/sqlite3', ['-readonly', _uri, "SELECT value FROM meta WHERE key='version';"]);
    return int.tryParse(out?.trim() ?? '') ?? 0;
  }
}

String _sqlList(List<String> values) =>
    [for (final v in values) "'${v.replaceAll("'", "''")}'"].join(',');

/// `Safe Storage` parolasından çözme anahtarı:
/// PBKDF2-HMAC-SHA1, tuz `saltysalt`, 1003 tur, 16 baytlık AES-128 anahtarı (macOS Chromium).
Uint8List deriveChromiumKey(String password) {
  final gen = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode('saltysalt')), 1003, 16));
  return gen.process(Uint8List.fromList(utf8.encode(password)));
}

/// Tek bir `v10` çerez değerini çözer. AES-128-CBC, IV 16 boşluk (0x20).
///
/// [metaVersion] >= 24 olan yeni Chromium'da düz metnin başında 32 baytlık alan adı SHA256'sı
/// bulunur ve atlanır (meta tablosundaki `version`). Çözülemezse null.
String? decryptChromiumCookie(Uint8List encrypted, Uint8List key, {required int metaVersion}) {
  // v10 öneki (0x76 0x31 0x30). Başka biçimleri (v11/düz) bu uygulama çözmez.
  if (encrypted.length < 3 || encrypted[0] != 0x76 || encrypted[1] != 0x31 || encrypted[2] != 0x30) {
    return null;
  }
  final body = Uint8List.sublistView(encrypted, 3);
  if (body.isEmpty || body.length % 16 != 0) return null;
  final iv = Uint8List(16)..fillRange(0, 16, 0x20);
  final cipher = CBCBlockCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(body.length);
  for (var off = 0; off < body.length; off += 16) {
    cipher.processBlock(body, off, out, off);
  }
  // PKCS7 dolgu.
  final pad = out.last;
  if (pad < 1 || pad > 16 || pad > out.length) return null;
  var plain = Uint8List.sublistView(out, 0, out.length - pad);
  if (metaVersion >= 24 && plain.length > 32) plain = Uint8List.sublistView(plain, 32);
  try {
    return utf8.decode(plain);
  } catch (_) {
    return null;
  }
}

Uint8List _fromHex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
