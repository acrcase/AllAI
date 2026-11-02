/// Çeviri tablosu: anahtar -> {dil kodu: metin}. Bkz. l10n.dart.
/// Üst çubuk, karşılama, dil seçimi ve sıfırlama metinleri.
const stringsCore = <String, Map<String, String>>{
  'core.greet.morning': {
    'en': 'Good morning', 'tr': 'Günaydın', 'de': 'Guten Morgen', 'ar': 'صباح الخير',
    'es': 'Buenos días', 'fr': 'Bonjour', 'ru': 'Доброе утро', 'zh': '早上好',
  },
  'core.greet.afternoon': {
    'en': 'Good afternoon', 'tr': 'İyi günler', 'de': 'Guten Tag', 'ar': 'نهارك سعيد',
    'es': 'Buenas tardes', 'fr': 'Bon après-midi', 'ru': 'Добрый день', 'zh': '下午好',
  },
  'core.greet.evening': {
    'en': 'Good evening', 'tr': 'İyi akşamlar', 'de': 'Guten Abend', 'ar': 'مساء الخير',
    'es': 'Buenas noches', 'fr': 'Bonsoir', 'ru': 'Добрый вечер', 'zh': '晚上好',
  },
  'core.greet.night': {
    'en': 'Good night', 'tr': 'İyi geceler', 'de': 'Gute Nacht', 'ar': 'طاب مساؤك',
    'es': 'Buenas noches', 'fr': 'Bonne nuit', 'ru': 'Доброй ночи', 'zh': '晚安',
  },
  'core.greet.question': {
    'en': 'Which one are we working with today?',
    'tr': 'Bugün hangisiyle çalışıyoruz?',
    'de': 'Mit welcher KI arbeiten wir heute?',
    'ar': 'مع أيّ منها سنعمل اليوم؟',
    'es': '¿Con cuál trabajamos hoy?',
    'fr': 'Avec laquelle travaille-t-on aujourd’hui ?',
    'ru': 'С какой работаем сегодня?',
    'zh': '今天用哪一个？',
  },
  'core.your_name': {
    'en': 'Your name', 'tr': 'Adın', 'de': 'Dein Name', 'ar': 'اسمك',
    'es': 'Tu nombre', 'fr': 'Ton nom', 'ru': 'Твоё имя', 'zh': '你的名字',
  },
  'core.name_tip': {
    'en': 'Tap to change your name', 'tr': 'Adını değiştirmek için dokun', 'de': 'Tippen, um deinen Namen zu ändern',
    'ar': 'اضغط لتغيير اسمك', 'es': 'Toca para cambiar tu nombre', 'fr': 'Touche pour changer ton nom',
    'ru': 'Нажми, чтобы изменить имя', 'zh': '点击修改名字',
  },
  'core.add': {
    'en': 'Add', 'tr': 'Ekle', 'de': 'Hinzufügen', 'ar': 'إضافة',
    'es': 'Añadir', 'fr': 'Ajouter', 'ru': 'Добавить', 'zh': '添加',
  },
  'core.edit': {
    'en': 'Edit', 'tr': 'Düzenle', 'de': 'Bearbeiten', 'ar': 'تعديل',
    'es': 'Editar', 'fr': 'Modifier', 'ru': 'Изменить', 'zh': '编辑',
  },
  'core.done': {
    'en': 'Done', 'tr': 'Bitti', 'de': 'Fertig', 'ar': 'تم',
    'es': 'Listo', 'fr': 'Terminé', 'ru': 'Готово', 'zh': '完成',
  },
  'core.home': {
    'en': 'Home', 'tr': 'Ana ekran', 'de': 'Startseite', 'ar': 'الرئيسية',
    'es': 'Inicio', 'fr': 'Accueil', 'ru': 'Главная', 'zh': '主页',
  },
  'core.back': {
    'en': 'Back', 'tr': 'Geri', 'de': 'Zurück', 'ar': 'رجوع',
    'es': 'Atrás', 'fr': 'Retour', 'ru': 'Назад', 'zh': '后退',
  },
  'core.forward': {
    'en': 'Forward', 'tr': 'İleri', 'de': 'Vor', 'ar': 'تقدّم',
    'es': 'Adelante', 'fr': 'Avancer', 'ru': 'Вперёд', 'zh': '前进',
  },
  'core.reload': {
    'en': 'Reload', 'tr': 'Yenile', 'de': 'Neu laden', 'ar': 'إعادة تحميل',
    'es': 'Recargar', 'fr': 'Actualiser', 'ru': 'Обновить', 'zh': '刷新',
  },
  'core.to_web': {
    'en': 'Switch to web version', 'tr': 'Web sürümüne geç', 'de': 'Zur Webversion wechseln', 'ar': 'التبديل إلى نسخة الويب',
    'es': 'Cambiar a la versión web', 'fr': 'Passer à la version web', 'ru': 'Перейти на веб-версию', 'zh': '切换到网页版',
  },
  'core.to_app': {
    'en': 'Switch to desktop app', 'tr': 'Mac uygulamasına geç', 'de': 'Zur Desktop-App wechseln', 'ar': 'التبديل إلى تطبيق سطح المكتب',
    'es': 'Cambiar a la app de escritorio', 'fr': 'Passer à l’application de bureau', 'ru': 'Перейти на приложение', 'zh': '切换到桌面应用',
  },
  'core.language': {
    'en': 'Language', 'tr': 'Dil', 'de': 'Sprache', 'ar': 'اللغة',
    'es': 'Idioma', 'fr': 'Langue', 'ru': 'Язык', 'zh': '语言',
  },
  'core.language.title': {
    'en': 'Choose language', 'tr': 'Dil seç', 'de': 'Sprache wählen', 'ar': 'اختر اللغة',
    'es': 'Elige el idioma', 'fr': 'Choisir la langue', 'ru': 'Выберите язык', 'zh': '选择语言',
  },
  'core.reset': {
    'en': 'Reset', 'tr': 'Sıfırla', 'de': 'Zurücksetzen', 'ar': 'إعادة ضبط',
    'es': 'Restablecer', 'fr': 'Réinitialiser', 'ru': 'Сбросить', 'zh': '重置',
  },
  'core.reset.title': {
    'en': 'Delete all AllAI data?', 'tr': 'AllAI’nin bütün verileri silinsin mi?', 'de': 'Alle AllAI-Daten löschen?',
    'ar': 'حذف جميع بيانات AllAI؟', 'es': '¿Borrar todos los datos de AllAI?', 'fr': 'Supprimer toutes les données d’AllAI ?',
    'ru': 'Удалить все данные AllAI?', 'zh': '删除 AllAI 的所有数据？',
  },
  'core.reset.body': {
    'en': 'Your name, language, cards, accounts, saved sessions, cache and usage history are deleted from this computer. AllAI closes afterwards and starts fresh next time. Other apps are not touched.',
    'tr': 'Adın, dil, kartlar, hesaplar, kayıtlı oturumlar, önbellek ve kullanım geçmişi bu bilgisayardan silinir. AllAI sonra kapanır ve bir sonraki açılışta sıfırdan başlar. Diğer uygulamalara dokunulmaz.',
    'de': 'Dein Name, Sprache, Karten, Konten, gespeicherte Sitzungen, Cache und Nutzungsverlauf werden von diesem Computer gelöscht. AllAI wird danach beendet und startet beim nächsten Mal neu. Andere Apps bleiben unberührt.',
    'ar': 'سيتم حذف اسمك ولغتك والبطاقات والحسابات والجلسات المحفوظة والذاكرة المؤقتة وسجل الاستخدام من هذا الكمبيوتر. سيُغلق AllAI بعد ذلك ويبدأ من جديد في المرة القادمة. لا يتم المساس بالتطبيقات الأخرى.',
    'es': 'Se borran de este ordenador tu nombre, idioma, tarjetas, cuentas, sesiones guardadas, caché e historial de uso. AllAI se cierra después y empieza de cero la próxima vez. Las demás apps no se tocan.',
    'fr': 'Ton nom, la langue, les cartes, les comptes, les sessions enregistrées, le cache et l’historique d’utilisation sont supprimés de cet ordinateur. AllAI se ferme ensuite et repart de zéro au prochain lancement. Les autres applications ne sont pas touchées.',
    'ru': 'Имя, язык, карточки, аккаунты, сохранённые сессии, кэш и история использования будут удалены с этого компьютера. После этого AllAI закроется и при следующем запуске начнёт с нуля. Другие приложения не затрагиваются.',
    'zh': '你的名字、语言、卡片、账户、已保存的会话、缓存和使用记录将从这台电脑上删除。之后 AllAI 会关闭，下次启动时从头开始。其他应用不受影响。',
  },
  'core.reset.confirm': {
    'en': 'Delete everything', 'tr': 'Hepsini sil', 'de': 'Alles löschen', 'ar': 'حذف كل شيء',
    'es': 'Borrar todo', 'fr': 'Tout supprimer', 'ru': 'Удалить всё', 'zh': '全部删除',
  },
  'core.cancel': {
    'en': 'Cancel', 'tr': 'Vazgeç', 'de': 'Abbrechen', 'ar': 'إلغاء',
    'es': 'Cancelar', 'fr': 'Annuler', 'ru': 'Отмена', 'zh': '取消',
  },
  'core.webview2.missing': {
    'en': 'Microsoft Edge WebView2 Runtime is missing or could not start. Install it from microsoft.com/edge/webview2 and restart AllAI.',
    'tr': 'Microsoft Edge WebView2 Runtime yok ya da başlatılamadı. microsoft.com/edge/webview2 adresinden kur ve AllAI\'yi yeniden başlat.',
    'de': 'Microsoft Edge WebView2 Runtime fehlt oder konnte nicht gestartet werden. Installiere es von microsoft.com/edge/webview2 und starte AllAI neu.',
    'ar': 'Microsoft Edge WebView2 Runtime غير مثبّت أو تعذّر تشغيله. ثبّته من microsoft.com/edge/webview2 ثم أعد تشغيل AllAI.',
    'es': 'Falta Microsoft Edge WebView2 Runtime o no pudo iniciarse. Instálalo desde microsoft.com/edge/webview2 y reinicia AllAI.',
    'fr': 'Microsoft Edge WebView2 Runtime est absent ou n’a pas pu démarrer. Installe-le depuis microsoft.com/edge/webview2 puis relance AllAI.',
    'ru': 'Microsoft Edge WebView2 Runtime отсутствует или не запустился. Установи его с microsoft.com/edge/webview2 и перезапусти AllAI.',
    'zh': '缺少 Microsoft Edge WebView2 Runtime，或它无法启动。请从 microsoft.com/edge/webview2 安装后重启 AllAI。',
  },
};
