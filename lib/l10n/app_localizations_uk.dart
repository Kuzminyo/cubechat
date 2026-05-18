// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Ukrainian (`uk`).
class AppLocalizationsUk extends AppLocalizations {
  AppLocalizationsUk([String locale = 'uk']) : super(locale);

  @override
  String get appName => 'Cubechat';

  @override
  String get navChats => 'Чати';

  @override
  String get navPeers => 'Поблизу';

  @override
  String get navProfile => 'Профіль';

  @override
  String get chatsTitle => 'Чати';

  @override
  String get chatsSubtitle => 'Mesh · наскрізне шифрування';

  @override
  String get chatsEmptyTitle => 'Поки що немає розмов';

  @override
  String get chatsEmptyHint =>
      'Відкрийте співрозмовника на вкладці «Поблизу», щоб почати спілкування.';

  @override
  String get chatsFilterAll => 'Усі';

  @override
  String get chatsFilterUnread => 'Непрочитані';

  @override
  String get chatsFilterMesh => 'Mesh';

  @override
  String get chatsFilterFavorites => 'Обрані';

  @override
  String get chatsSearchHint => 'Пошук чатів…';

  @override
  String get peersTitle => 'Поблизу';

  @override
  String get peersSubtitle => 'Пристрої у радіусі Bluetooth';

  @override
  String get peersEmpty => 'Шукаємо співрозмовників…';

  @override
  String peersHopsOne(int n) {
    return '$n пересилання';
  }

  @override
  String peersHopsOther(int n) {
    return '$n пересилань';
  }

  @override
  String get blePermissionTitle => 'Потрібен дозвіл на Bluetooth';

  @override
  String get blePermissionHint =>
      'Cubechat використовує Bluetooth для пошуку співрозмовників і надсилання повідомлень — без інтернету.';

  @override
  String get blePermissionGrant => 'Надати дозвіл';

  @override
  String get blePermissionOpenSettings => 'Відкрити налаштування';

  @override
  String get blePermissionDeniedHint =>
      'У дозволі відмовлено. Відкрийте налаштування, щоб дозволити доступ до Bluetooth.';

  @override
  String get bleAdapterOffTitle => 'Bluetooth вимкнено';

  @override
  String get bleAdapterOffHint =>
      'Увімкніть Bluetooth, щоб побачити пристрої поблизу.';

  @override
  String get bleUnsupportedTitle => 'Bluetooth LE недоступний';

  @override
  String get bleUnsupportedHint =>
      'Цей пристрій або платформа не підтримує Bluetooth Low Energy. Спробуйте на смартфоні.';

  @override
  String get bleScanning => 'Сканування…';

  @override
  String get bleRetry => 'Повторити';

  @override
  String get bleSignal => 'Сигнал';

  @override
  String get bleConnect => 'З\'єднатися';

  @override
  String get bleConnected => 'З\'єднано';

  @override
  String get bleVerified => 'Перевірено';

  @override
  String get bleUnknownPeer => 'Невідомий пристрій';

  @override
  String get bleBroadcasting => 'В ефірі';

  @override
  String bleConnectedCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n центральних пристроїв',
      few: '$n центральних пристрої',
      one: '1 центральний пристрій',
      zero: 'Немає з\'єднань',
    );
    return '$_temp0';
  }

  @override
  String get chatInputHint => 'Повідомлення';

  @override
  String get chatSend => 'Надіслати';

  @override
  String get chatToday => 'Сьогодні';

  @override
  String get chatYesterday => 'Учора';

  @override
  String get chatDelivered => 'Доставлено';

  @override
  String get chatRead => 'Прочитано';

  @override
  String get chatSending => 'Надсилається';

  @override
  String get chatEncryptedNotice =>
      'Повідомлення зашифровано наскрізно за протоколом Noise.';

  @override
  String get chatSessionHandshaking => 'Встановлюється захищений канал…';

  @override
  String get chatSessionEstablished => 'Захищено · Noise XX';

  @override
  String get chatSessionFailed => 'З\'єднання не вдалося';

  @override
  String get chatSessionFingerprintPending =>
      'Відбиток з\'явиться після завершення рукостискання.';

  @override
  String get chatEmptyEstablished =>
      'Захищений канал готовий. Надішліть повідомлення, щоб почати розмову.';

  @override
  String get chatEmptyHandshaking =>
      'Очікуємо, поки інший бік завершить рукостискання…';

  @override
  String get profileTitle => 'Профіль';

  @override
  String get profileNickname => 'Нікнейм';

  @override
  String get profileNicknameEditTitle => 'Встановіть нікнейм';

  @override
  String get profileNicknameHint => 'Як вас побачать інші у mesh-мережі';

  @override
  String get profileNicknameSave => 'Зберегти';

  @override
  String get profileFingerprint => 'Відбиток публічного ключа';

  @override
  String get profileLanguage => 'Мова';

  @override
  String get profileLanguageEn => 'Англійська';

  @override
  String get profileLanguageUk => 'Українська';

  @override
  String get profileTransport => 'Транспорт';

  @override
  String get profileTransportMesh => 'Bluetooth mesh';

  @override
  String get profileAbout => 'Про застосунок';

  @override
  String profileVersion(String v) {
    return 'Версія $v';
  }

  @override
  String get profileEmergencyWipe => 'Аварійне очищення';

  @override
  String get profileEmergencyWipeHint =>
      'Потрійний тап стирає всі ключі, контакти й повідомлення.';

  @override
  String get profileEmergencyWipeConfirm => 'Стерти все?';

  @override
  String get profileEmergencyWipeConfirmHint =>
      'Буде видалено вашу ідентичність, список контактів та історію розмов. Дію не можна скасувати.';

  @override
  String get profileEmergencyWipeAction => 'Стерти';

  @override
  String get cancel => 'Скасувати';

  @override
  String get copy => 'Копіювати';

  @override
  String get copied => 'Скопійовано';
}
