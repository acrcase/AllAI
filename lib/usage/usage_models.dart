/// Kullanım limitleri veri sözleşmesi.
///
/// Kaynaklar (lib/usage/sources) bunları üretir, panel (lib/ui/usage) bunları çizer.
library;

enum UsageStatus {
  /// Veri geldi.
  ok,

  /// Henüz çekilmedi / çekiliyor.
  loading,

  /// Oturum yok: kullanıcı ilgili yapay zekâyı uygulama içinde açıp giriş yapmalı.
  needsLogin,

  /// Okuma kullanıcı onayı bekliyor (anahtarlık izni); satırda "bağla" düğmesi gösterilir.
  needsConsent,

  /// Bu cihazda bu kaynak yok (ör. Android'de yerel dosya, uygulama kurulu değil).
  unavailable,

  /// Hizmet kalan hakkı yayımlamıyor; yalnız plan bilgisi / tahmin var.
  noData,

  /// Çekerken hata oluştu.
  error,
}

/// Tek bir limit çubuğu: "Claude Opus 5.5 (High)", "5 saatlik oturum" gibi.
class UsageMeter {
  const UsageMeter({
    required this.label,
    this.remaining,
    this.detail,
    this.resetsAt,
    this.estimated = false,
    this.unlimited = false,
  });

  final String label;

  /// Kalan oran 0..1. Bilinmiyorsa null.
  final double? remaining;

  /// Ek metin: "184 / 200 istek", "~12 istem kaldı", "günde 100 istem".
  final String? detail;

  final DateTime? resetsAt;

  /// Değer ölçülmedi, tahmin edildi (panelde "tahmini" etiketi).
  final bool estimated;

  /// Sınırsız (çubuk dolu ve "sınırsız" yazar).
  final bool unlimited;

  Map<String, Object?> toJson() => {
        'label': label,
        'remaining': remaining,
        'detail': detail,
        'resetsAt': resetsAt?.toIso8601String(),
        'estimated': estimated,
        'unlimited': unlimited,
      };

  factory UsageMeter.fromJson(Map<String, Object?> j) => UsageMeter(
        label: j['label']! as String,
        remaining: (j['remaining'] as num?)?.toDouble(),
        detail: j['detail'] as String?,
        resetsAt: j['resetsAt'] == null ? null : DateTime.tryParse(j['resetsAt']! as String),
        estimated: (j['estimated'] as bool?) ?? false,
        unlimited: (j['unlimited'] as bool?) ?? false,
      );
}

/// Bir uygulama içindeki gruplama: "Oturum limitleri", "Claude modelleri", "Gemini modelleri".
class UsageSection {
  const UsageSection({this.title, required this.meters});

  final String? title;
  final List<UsageMeter> meters;

  Map<String, Object?> toJson() => {
        'title': title,
        'meters': [for (final m in meters) m.toJson()],
      };

  factory UsageSection.fromJson(Map<String, Object?> j) => UsageSection(
        title: j['title'] as String?,
        meters: [
          for (final m in (j['meters'] as List? ?? const []))
            UsageMeter.fromJson((m as Map).cast<String, Object?>()),
        ],
      );
}

/// Bir uygulamanın (ChatGPT, Antigravity, ...) bütün limitleri.
class UsageReport {
  const UsageReport({
    required this.serviceId,
    required this.title,
    required this.status,
    required this.fetchedAt,
    this.plan,
    this.message,
    this.source,
    this.sections = const [],
    this.actionLabel,
    this.connected = false,
  });

  /// `AiService.usageKey` ile eşleşir.
  final String serviceId;
  final String title;
  final UsageStatus status;

  /// "Google AI Pro", "Max 20x", "Free" ...
  final String? plan;

  /// Kullanıcıya açıklama: "Giriş yapınca görünür", "Antigravity kurulu değil" ...
  final String? message;

  /// Verinin nereden geldiği (panelde küçük yazı): "Antigravity yerel sunucusu".
  final String? source;

  final List<UsageSection> sections;
  final DateTime fetchedAt;

  /// Onay gereken satırda "bağla" düğmesinin metni (ör. "Chrome'daki Claude hesabını bağla").
  final String? actionLabel;

  /// Kullanıcı bu kaynağı bağladı mı: kartta "bağlantıyı kes" seçeneği gösterilir.
  final bool connected;

  /// En düşük kalan oran (kart rozetleri ve özet için).
  double? get lowestRemaining {
    double? low;
    for (final s in sections) {
      for (final m in s.meters) {
        final r = m.unlimited ? 1.0 : m.remaining;
        if (r != null && (low == null || r < low)) low = r;
      }
    }
    return low;
  }

  UsageReport copyWith({UsageStatus? status, String? message}) => UsageReport(
        serviceId: serviceId,
        title: title,
        status: status ?? this.status,
        fetchedAt: fetchedAt,
        plan: plan,
        message: message ?? this.message,
        source: source,
        sections: sections,
        actionLabel: actionLabel,
        connected: connected,
      );

  Map<String, Object?> toJson() => {
        'serviceId': serviceId,
        'title': title,
        'status': status.name,
        'plan': plan,
        'message': message,
        'source': source,
        'sections': [for (final s in sections) s.toJson()],
        'fetchedAt': fetchedAt.toIso8601String(),
        'actionLabel': actionLabel,
        'connected': connected,
      };

  factory UsageReport.fromJson(Map<String, Object?> j) => UsageReport(
        serviceId: j['serviceId']! as String,
        title: j['title']! as String,
        status: UsageStatus.values.asNameMap()[j['status']] ?? UsageStatus.error,
        plan: j['plan'] as String?,
        message: j['message'] as String?,
        source: j['source'] as String?,
        sections: [
          for (final s in (j['sections'] as List? ?? const []))
            UsageSection.fromJson((s as Map).cast<String, Object?>()),
        ],
        fetchedAt: DateTime.tryParse(j['fetchedAt'] as String? ?? '') ?? DateTime.now(),
        actionLabel: j['actionLabel'] as String?,
        connected: (j['connected'] as bool?) ?? false,
      );
}
