import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// Bir sitenin internetten çekilmiş simgesi ve ondan çıkarılan marka renkleri.
class SiteIcon {
  const SiteIcon(this.path, this.color, this.accent);

  /// Yerel PNG dosyası (mutlak yol).
  final String path;
  final Color color;
  final Color accent;

  static const _timeout = Duration(seconds: 6);
  static const _maxBytes = 2 * 1024 * 1024;

  /// Siteden en iyi simgeyi indirir: sayfadaki `apple-touch-icon` / `icon` bağlantıları (büyük olan önce),
  /// sonra kök dizindeki dosyalar, en son Google'ın favicon servisi. Bulunamazsa null.
  static Future<SiteIcon?> fetch(Uri site) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final candidates = [
        ...await _pageIcons(client, site),
        site.resolve('/apple-touch-icon.png'),
        site.resolve('/favicon.ico'),
        Uri.https('www.google.com', '/s2/favicons', {
          'domain': site.host,
          'sz': '128',
        }),
      ];
      ui.Image? best;
      for (final url in candidates) {
        final image = await _download(client, url);
        if (image == null) continue;
        if (best == null || image.width > best.width) best = image;
        if (best.width >= 128) break;
      }
      if (best == null) return null;
      final png = await best.toByteData(format: ui.ImageByteFormat.png);
      final raw = await best.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (png == null || raw == null) return null;
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/icons',
      );
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}/${site.host.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '_')}.png',
      );
      await file.writeAsBytes(png.buffer.asUint8List());
      final (color, accent) = brand(raw.buffer.asUint8List());
      return SiteIcon(file.path, color, accent);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<Uri>> _pageIcons(HttpClient client, Uri site) async {
    final bytes = await _get(
      client,
      site.replace(path: site.path.isEmpty ? '/' : site.path, query: ''),
      600 * 1024,
    );
    if (bytes == null) return const [];
    final html = String.fromCharCodes(bytes);
    final found = <(int, Uri)>[];
    for (final m in RegExp(
      r'<link\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final tag = m.group(0)!;
      String? attr(String name) => RegExp(
        '$name\\s*=\\s*["\']([^"\']*)["\']',
        caseSensitive: false,
      ).firstMatch(tag)?.group(1);
      final rel = attr('rel')?.toLowerCase() ?? '';
      final href = attr('href');
      if (href == null || !rel.contains('icon')) continue;
      final size =
          int.tryParse(
            RegExp(r'(\d+)x\d+').firstMatch(attr('sizes') ?? '')?.group(1) ??
                '',
          ) ??
          0;
      final uri = site.resolve(href);
      if (uri.scheme.startsWith('http')) {
        found.add((size + (rel.contains('apple') ? 1000 : 0), uri));
      }
    }
    found.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final f in found) f.$2];
  }

  static Future<Uint8List?> _get(HttpClient client, Uri url, int limit) async {
    try {
      final request = await client.getUrl(url).timeout(_timeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Macintosh) AllAI',
      );
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_timeout)) {
        out.add(chunk);
        if (out.length >= limit) break;
      }
      return out.takeBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> _download(HttpClient client, Uri url) async {
    final bytes = await _get(client, url, _maxBytes);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null; // HTML hata sayfası, bozuk ya da desteklenmeyen biçim
    }
  }

  /// Doygun, ne çok koyu ne çok açık piksellerin dairesel ortalama tonu; hiç yoksa (siyah-beyaz simge) nötr.
  /// RGBA piksellerinden marka rengi ve vurgu rengi.
  static (Color, Color) brand(Uint8List rgba) {
    var sx = 0.0, sy = 0.0, weight = 0.0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final c = HSLColor.fromColor(
        Color.fromARGB(rgba[i + 3], rgba[i], rgba[i + 1], rgba[i + 2]),
      );
      if (rgba[i + 3] < 200 ||
          c.saturation < 0.3 ||
          c.lightness < 0.15 ||
          c.lightness > 0.88) {
        continue;
      }
      final w = c.saturation;
      sx += math.cos(c.hue * math.pi / 180) * w;
      sy += math.sin(c.hue * math.pi / 180) * w;
      weight += w;
    }
    if (weight < rgba.length / 4 * 0.01) {
      return (const Color(0xFF5B6475), const Color(0xFFB5BDCC));
    }
    final hue = (math.atan2(sy, sx) * 180 / math.pi + 360) % 360;
    return (
      HSLColor.fromAHSL(1, hue, 0.65, 0.5).toColor(),
      HSLColor.fromAHSL(1, hue, 0.85, 0.74).toColor(),
    );
  }
}
