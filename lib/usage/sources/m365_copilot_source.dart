import '../usage_models.dart';
import 'common.dart';
import '../../l10n/l10n.dart';

/// Microsoft Copilot (Microsoft 365 Copilot uygulaması / m365.cloud.microsoft): kalan hak
/// yayımlanmıyor; yalnız belgedeki nitel limit.
class M365CopilotSource extends BaseSource {
  @override
  String get serviceId => 'm365-copilot';

  @override
  String get title => 'Microsoft Copilot';

  // Microsoft 365 bireysel planlarında sohbet "yoğun kullanım"; sayı verilmiyor, kalan durum
  // Microsoft hesabı > Hizmetler ve abonelikler'de.
  // Kaynak: https://support.microsoft.com/office/68530f1a-4459-4d02-9818-8233c1f673b8
  // (kontrol 24 Eki 2026; sayfa "Ekim 2026" güncel).
  @override
  Future<UsageReport> load() async => report(
        UsageStatus.noData,
        message: t('usage.m365.message'),
        source: t('usage.m365.source'),
        sections: [
          UsageSection(meters: [
            UsageMeter(label: t('usage.chat'), detail: t('usage.m365.detail')),
          ]),
        ],
      );
}
