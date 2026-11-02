import 'dart:io';
import 'dart:typed_data';

import 'package:allai/usage/cookie_store.dart';
import 'package:flutter_test/flutter_test.dart';

// Vektörler bağımsız araçlarla üretildi (Python hashlib.pbkdf2_hmac + openssl aes-128-cbc),
// sahte parola 'test-pass-123' ve sahte değer 'fake-session-abc' ile. Gerçek anahtarlık/çerez
// kullanılmadı. Çözücünün biçimi doğru çözdüğünü kanıtlar.
const _password = 'test-pass-123';
const _expectedKeyHex = 'f6ac53970dfb7c033c5a42a6a943dc4f';

// v10 + AES-128-CBC(IV=16×0x20), düz metin = sha256('claude.ai') + 'fake-session-abc' (version 24).
const _encV24 =
    '76313008f7bbfc523d35b7871b09005537fcf73bcc6e06257932166f709e979c'
    '1d4aa7b06694d29f091e723191c9c4d8c642bec8889be89a79ca2904411387c44bba20';

// Aynı anahtar/IV, 32-baytlık önek YOK (eski biçim): düz metin = 'fake-session-abc'.
const _encNoPrefix = '7631300e7a565e45f89bb9feaee68c609c51afc440d7ad544553afa4551309d0e9ad4d';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// sqlite3 çağrılarını taklit eder: meta->24, cookies SELECT->tek satır (sessionKey, v24 şifreli).
String? _fakeSqlite(String exe, List<String> args) {
  final sql = args.last;
  if (sql.contains('FROM meta')) return '24';
  if (sql.contains('FROM cookies')) {
    // host_key \x1e name \x1e value \x1e hex(encrypted_value) \x1f
    return '.claude.ai\x1esessionKey\x1e\x1e$_encV24\x1f';
  }
  return null;
}

void main() {
  group('deriveChromiumKey', () {
    test('PBKDF2-SHA1(saltysalt, 1003, 16) bağımsız vektörle eşleşir', () {
      final key = deriveChromiumKey(_password);
      expect(key, hasLength(16));
      final hex = [for (final b in key) b.toRadixString(16).padLeft(2, '0')].join();
      expect(hex, _expectedKeyHex);
    });
  });

  group('decryptChromiumCookie', () {
    final key = deriveChromiumKey(_password);

    test('version 24: 32-baytlık alan öneki atlanır', () {
      expect(decryptChromiumCookie(_hex(_encV24), key, metaVersion: 24), 'fake-session-abc');
    });

    test('eski biçim (önek yok): tüm düz metin değerdir', () {
      expect(decryptChromiumCookie(_hex(_encNoPrefix), key, metaVersion: 20), 'fake-session-abc');
    });

    test('yanlış anahtarla UTF-8 çözülemez -> null', () {
      final wrong = deriveChromiumKey('wrong');
      expect(decryptChromiumCookie(_hex(_encV24), wrong, metaVersion: 24), isNull);
    });

    test('v10 öneki yoksa null', () {
      expect(decryptChromiumCookie(_hex('deadbeef'), key, metaVersion: 24), isNull);
    });

    test('blok hizası bozuksa null', () {
      expect(decryptChromiumCookie(_hex('76313000'), key, metaVersion: 24), isNull);
    });
  });

  group('ChromiumCookieStore.read', () {
    test('DB yoksa hiçbir komut/anahtarlık çalışmaz, null', () async {
      final store = ChromiumCookieStore(
        cookiesDbPath: '/var/empty/does-not-exist/Cookies',
        safeStorageService: 'Fake Safe Storage',
        runProcess: (_, _) async => fail('DB yokken komut çalışmamalı'),
        passwordReader: (_) async => fail('DB yokken anahtarlık okunmamalı'),
      );
      expect(await store.read(hosts: const ['claude.ai'], names: const ['sessionKey']), isNull);
    });

    test('okuma sırasında forgetKey olursa sonuç atılır (bağlantıyı kes yarışı)', () async {
      final db = await File('${Directory.systemTemp.createTempSync('ck').path}/Cookies').create();
      addTearDown(() => db.parent.delete(recursive: true));
      late ChromiumCookieStore store;
      store = ChromiumCookieStore(
        cookiesDbPath: db.path,
        safeStorageService: 'Fake Safe Storage',
        runProcess: (exe, args) async => _fakeSqlite(exe, args),
        passwordReader: (_) async {
          store.forgetKey(); // parola dönerken bağlantı kesildi
          return _password;
        },
      );
      expect(await store.read(hosts: const ['claude.ai'], names: const ['sessionKey']), isNull);
    });

    test('dar sorgu + çözme; parola/değer alt süreç argümanına girmez; anahtarlık bir kez okunur',
        () async {
      final db = await File('${Directory.systemTemp.createTempSync('ck').path}/Cookies').create();
      addTearDown(() => db.parent.delete(recursive: true));
      final sqlArgs = <String>[];
      var passwordReads = 0;
      final store = ChromiumCookieStore(
        cookiesDbPath: db.path,
        safeStorageService: 'Fake Safe Storage',
        runProcess: (exe, args) async {
          sqlArgs.addAll(args);
          return _fakeSqlite(exe, args);
        },
        passwordReader: (_) async {
          passwordReads++;
          return _password; // sahte "sır"
        },
      );

      final c1 = await store.read(
          hosts: const ['claude.ai', '.claude.ai'], names: const ['sessionKey', 'cf_clearance']);
      expect(c1, isNotNull);
      expect(c1!.single.name, 'sessionKey');
      expect(c1.single.value, 'fake-session-abc');

      // İkinci okuma: anahtarlık yeniden OKUNMAZ (türetilen anahtar önbellekte).
      await store.read(hosts: const ['claude.ai'], names: const ['sessionKey']);
      expect(passwordReads, 1, reason: 'oturum boyu anahtarlık bir kez okunur');

      // Dar sorgu: yalnız istenen host/name; başka host yakalanmaz.
      final joined = sqlArgs.join('\u0000');
      expect(joined, contains("host_key IN ('claude.ai','.claude.ai')"));
      expect(joined, contains("name IN ('sessionKey','cf_clearance')"));
      expect(joined, isNot(contains('LIKE')));
      // KRİTİK: parola ve çözülmüş çerez değeri hiçbir alt süreç argümanında yok.
      expect(joined, isNot(contains(_password)));
      expect(joined, isNot(contains('fake-session-abc')));

      // forgetKey sonrası anahtarlık yeniden okunur (bağlantıyı kesince).
      store.forgetKey();
      await store.read(hosts: const ['claude.ai'], names: const ['sessionKey']);
      expect(passwordReads, 2);
    });
  });
}
