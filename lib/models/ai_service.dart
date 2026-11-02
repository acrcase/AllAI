import 'package:flutter/painting.dart';
import '../l10n/l10n.dart';

/// Bir yapay zekânın uygulama içinde nasıl açılacağı.
enum OpenMode {
  /// Gömülü web görünümü (her platformda çalışır).
  web,

  /// macOS'ta kurulu uygulamanın penceresi bizim pencerenin içine yerleştirilir.
  app,
}

class AiService {
  const AiService({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.color,
    required this.accent,
    required this.usageKey,
    this.icon,
    this.webUrl,
    this.macBundleId,
    this.mode = OpenMode.web,
    this.isWebBadge = false,
    this.custom = false,
    this.profileOf,
    this.appPath,
  });

  /// Kalıcı kimlik (sıralama ve ayarlar bununla saklanır).
  final String id;
  final String name;
  final String subtitle;

  /// Varlık yolu (assets/icons/...). Yoksa baş harfli rozet çizilir.
  final String? icon;
  final Color color;
  final Color accent;

  final String? webUrl;
  final String? macBundleId;

  /// Windows'ta kullanıcının eklediği programın (.exe) mutlak yolu. Yerleştirme yok: kart tıklanınca
  /// program kendi penceresinde açılır. Eski kayıtlarda yok (null).
  final String? appPath;
  final OpenMode mode;

  /// Simgenin köşesine "web" rozeti çizilir (aynı markanın web sürümü).
  final bool isWebBadge;

  /// Kullanım panelindeki bölümün kimliği (`UsageReport.serviceId`).
  final String usageKey;

  /// Kullanıcının eklediği özel kart.
  final bool custom;

  /// Aynı uygulamanın ikinci hesabı: hangi kartın kopyası olduğu. Uygulama ayrı bir
  /// veri klasörüyle (ayrı oturum) ayrı bir örnek olarak açılır.
  final String? profileOf;

  /// Kullanıcının eklediği uygulama kartlarının kayıtlı alt başlığı; ekranda çevrilir.
  static const appSubtitle = 'Uygulama';

  bool get separateProfile => profileOf != null;

  /// Gösterim alt başlığı. Kayıtlı `Hesap <n>` değeri bozulmaz; yalnız ekranda çevrilir.
  String get displaySubtitle {
    if (custom && profileOf == null && subtitle == appSubtitle && (canApp || canLaunch)) return t('home.app_sub');
    if (profileOf == null) return subtitle;
    final n = RegExp(r'^Hesap (\d+)$').firstMatch(subtitle)?.group(1);
    return n == null ? subtitle : t('home.account_n', {'n': n});
  }

  bool get canWeb => webUrl != null;
  bool get canApp => macBundleId != null;

  /// Windows programı: yerleşmez, kendi penceresinde açılır.
  bool get canLaunch => appPath != null;

  AiService copyWith({OpenMode? mode, String? icon, Color? color, Color? accent}) => AiService(
        id: id,
        name: name,
        subtitle: subtitle,
        icon: icon ?? this.icon,
        color: color ?? this.color,
        accent: accent ?? this.accent,
        webUrl: webUrl,
        macBundleId: macBundleId,
        mode: mode ?? this.mode,
        isWebBadge: isWebBadge,
        usageKey: usageKey,
        custom: custom,
        profileOf: profileOf,
        appPath: appPath,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'subtitle': subtitle,
        'icon': icon,
        'color': color.toARGB32(),
        'accent': accent.toARGB32(),
        'webUrl': webUrl,
        'macBundleId': macBundleId,
        'mode': mode.name,
        'isWebBadge': isWebBadge,
        'usageKey': usageKey,
        'custom': custom,
        if (profileOf != null) 'profileOf': profileOf,
        if (appPath != null) 'appPath': appPath,
      };

  factory AiService.fromJson(Map<String, Object?> j) => AiService(
        id: j['id']! as String,
        name: j['name']! as String,
        subtitle: (j['subtitle'] as String?) ?? '',
        icon: j['icon'] as String?,
        color: Color(j['color']! as int),
        accent: Color(j['accent']! as int),
        webUrl: j['webUrl'] as String?,
        macBundleId: j['macBundleId'] as String?,
        mode: OpenMode.values.asNameMap()[j['mode']] ?? OpenMode.web,
        isWebBadge: (j['isWebBadge'] as bool?) ?? false,
        usageKey: (j['usageKey'] as String?) ?? j['id']! as String,
        custom: (j['custom'] as bool?) ?? false,
        profileOf: j['profileOf'] as String?,
        appPath: j['appPath'] as String?,
      );
}

