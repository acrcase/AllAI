/// Çeviri tablosu: anahtar -> {dil kodu: metin}. Bkz. l10n.dart.
/// macOS yerel katmanından (Swift) gelen menü ve hata metinleri.
/// `native.err.*`: Swift'in gönderdiği hata KODLARI (`err.xxx`); bkz. DockEvent.localizedMessage.
const stringsNative = <String, Map<String, String>>{
  'native.menu.go': {
    'en': 'Go', 'tr': 'Git', 'de': 'Gehe zu', 'ar': 'انتقال', 'es': 'Ir', 'fr': 'Aller', 'ru': 'Переход', 'zh': '前往',
  },
  'native.menu.home': {
    'en': 'Home', 'tr': 'Ana ekran', 'de': 'Startseite', 'ar': 'الشاشة الرئيسية', 'es': 'Inicio', 'fr': 'Accueil', 'ru': 'Главный экран', 'zh': '主屏幕',
  },
  'native.menu.reload': {
    'en': 'Reload', 'tr': 'Yenile', 'de': 'Neu laden', 'ar': 'إعادة تحميل', 'es': 'Recargar', 'fr': 'Actualiser', 'ru': 'Обновить', 'zh': '重新加载',
  },
  'native.menu.back': {
    'en': 'Back', 'tr': 'Geri', 'de': 'Zurück', 'ar': 'رجوع', 'es': 'Atrás', 'fr': 'Retour', 'ru': 'Назад', 'zh': '后退',
  },
  'native.menu.forward': {
    'en': 'Forward', 'tr': 'İleri', 'de': 'Vorwärts', 'ar': 'إلى الأمام', 'es': 'Adelante', 'fr': 'Avancer', 'ru': 'Вперёд', 'zh': '前进',
  },
  'native.menu.service': {
    'en': 'AI #{n}', 'tr': '{n}. yapay zekâ', 'de': 'KI {n}', 'ar': 'الذكاء الاصطناعي {n}', 'es': 'IA {n}', 'fr': 'IA {n}', 'ru': 'ИИ {n}', 'zh': 'AI {n}',
  },
  'native.err.secondAccountUnsupported': {
    'en': 'This app cannot be opened with a second account.',
    'tr': 'Bu uygulama ikinci hesapla açılamıyor.',
    'de': 'Diese App kann nicht mit einem zweiten Konto geöffnet werden.',
    'ar': 'لا يمكن فتح هذا التطبيق بحساب ثانٍ.',
    'es': 'Esta app no se puede abrir con una segunda cuenta.',
    'fr': 'Cette app ne peut pas s’ouvrir avec un deuxième compte.',
    'ru': 'Это приложение нельзя открыть со вторым аккаунтом.',
    'zh': '此应用无法使用第二个账户打开。',
  },
  'native.err.chromeHidden': {
    'en': 'Chrome is hidden (⌘H). Show Chrome and try again.',
    'tr': 'Chrome gizli (⌘H). Chrome\'u gösterip yeniden dene.',
    'de': 'Chrome ist ausgeblendet (⌘H). Chrome einblenden und erneut versuchen.',
    'ar': 'Chrome مخفي (⌘H). أظهر Chrome ثم أعد المحاولة.',
    'es': 'Chrome está oculto (⌘H). Muéstralo e inténtalo de nuevo.',
    'fr': 'Chrome est masqué (⌘H). Affichez-le puis réessayez.',
    'ru': 'Chrome скрыт (⌘H). Покажите Chrome и повторите попытку.',
    'zh': 'Chrome 已隐藏 (⌘H)。请显示 Chrome 后重试。',
  },
  'native.err.chromeUnresponsive': {
    'en': 'Chrome is not responding; try again in a moment.',
    'tr': 'Chrome yanıt vermiyor; birazdan yeniden dene.',
    'de': 'Chrome reagiert nicht; versuche es gleich noch einmal.',
    'ar': 'Chrome لا يستجيب؛ أعد المحاولة بعد قليل.',
    'es': 'Chrome no responde; inténtalo de nuevo en un momento.',
    'fr': 'Chrome ne répond pas ; réessayez dans un instant.',
    'ru': 'Chrome не отвечает; повторите попытку чуть позже.',
    'zh': 'Chrome 没有响应，请稍后重试。',
  },
  'native.err.chromeBusy': {
    'en': 'Another Chrome window opened at the same time; try again.',
    'tr': 'Chrome\'da aynı anda başka pencere açıldı; yeniden dene.',
    'de': 'Gleichzeitig wurde ein weiteres Chrome-Fenster geöffnet; versuche es erneut.',
    'ar': 'فُتحت نافذة Chrome أخرى في الوقت نفسه؛ أعد المحاولة.',
    'es': 'Se abrió otra ventana de Chrome al mismo tiempo; inténtalo de nuevo.',
    'fr': 'Une autre fenêtre Chrome s’est ouverte en même temps ; réessayez.',
    'ru': 'Одновременно открылось другое окно Chrome; повторите попытку.',
    'zh': 'Chrome 同时打开了另一个窗口，请重试。',
  },
};
