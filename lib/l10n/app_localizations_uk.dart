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
  String get chatsStatusViaMesh => 'через mesh';

  @override
  String get chatsStatusOffline => 'офлайн';

  @override
  String get peerKeyRotated => 'ключ змінено — підтвердьте знову';

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
  String get bleConnectFailed =>
      'Не вдалося підключитися. Пір поза зоною дії або його Bluetooth-адресу змінено.';

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
  String get verifyTitle => 'Підтвердження';

  @override
  String get verifyIntro =>
      'Порівняйте ці два відбитки зі своїм співрозмовником особисто або по голосовому виклику. Якщо вони збігаються з обох сторін — рукостискання Noise не було підмінене.';

  @override
  String get verifyMine => 'ВАШ ВІДБИТОК';

  @override
  String verifyTheirs(String name) {
    return 'ВІДБИТОК $name';
  }

  @override
  String get verifyMarkAsVerified => 'Підтвердити особу';

  @override
  String get verifyAlreadyDone => 'Особу цього співрозмовника підтверджено.';

  @override
  String get verifyRevoke => 'Скасувати';

  @override
  String verifyDoneSnack(String name) {
    return '$name: особу підтверджено';
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
  String get presenceOnline => 'у мережі';

  @override
  String get presenceOffline => 'не в мережі';

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
  String get profileBackground => 'Працювати у фоні';

  @override
  String get profileBackgroundSubtitle =>
      'Отримувати повідомлення, коли застосунок закрито';

  @override
  String get profileBatteryExempt => 'Вимкнути оптимізацію батареї';

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

  @override
  String get channelsNewTitle => 'Новий канал';

  @override
  String get channelsNewTooltip => 'Новий канал';

  @override
  String get channelNameLabel => 'Назва каналу';

  @override
  String get channelPasswordLabel => 'Пароль (необов’язково)';

  @override
  String get channelJoinAction => 'Приєднатися';

  @override
  String get channelSubtitle => 'Груповий канал · спільний ключ';

  @override
  String get chatsStatusChannel => 'канал';

  @override
  String get channelInviteTitle => 'Додати учасників';

  @override
  String get channelInviteAction => 'Запросити';

  @override
  String get channelInviteEmpty =>
      'Поки немає відомих пірів. Спершу знайдіть когось на вкладці «Поруч».';

  @override
  String get channelInviteSent => 'Запрошення надіслано';

  @override
  String get channelInviteNoneSent => 'Зараз нікого не вдалося досягнути';

  @override
  String get channelNameTooLong => 'Назва каналу задовга';

  @override
  String get chatsActionFavorite => 'Додати в обрані';

  @override
  String get chatsActionUnfavorite => 'Прибрати з обраних';

  @override
  String get chatsActionDelete => 'Видалити чат';

  @override
  String get chatsDeleteTitle => 'Видалити цей чат?';

  @override
  String get chatsDeletePeerHint =>
      'Розмову буде видалено, а піра забуто. Він зможе знайти вас знову через меш.';

  @override
  String get chatsDeleteChannelHint =>
      'Ви вийдете з каналу та видалите його історію. Щоб повернутися, знадобиться ключ.';

  @override
  String get chatEditAction => 'Редагувати';

  @override
  String get chatEditTitle => 'Редагувати повідомлення';

  @override
  String get chatEditSave => 'Зберегти';

  @override
  String get chatEdited => 'змінено';

  @override
  String get chatDeleteAction => 'Видалити';

  @override
  String get chatDeleteTitle => 'Видалити повідомлення?';

  @override
  String get chatDeleteForMe => 'Видалити в мене';

  @override
  String get chatDeleteForEveryone => 'Видалити в усіх';

  @override
  String get chatReplyAction => 'Відповісти';

  @override
  String chatReplyingTo(String name) {
    return 'Відповідь для $name';
  }

  @override
  String get chatReplyYou => 'себе';

  @override
  String get chatCopyAction => 'Копіювати';

  @override
  String get chatCopied => 'Скопійовано';

  @override
  String get chatForwardAction => 'Переслати';

  @override
  String get chatForwardTitle => 'Переслати в';

  @override
  String get chatForwardEmpty => 'Інших чатів поки немає';

  @override
  String chatForwardSent(String name) {
    return 'Переслано в $name';
  }

  @override
  String get peerBlock => 'Заблокувати';

  @override
  String get peerUnblock => 'Розблокувати';

  @override
  String get peerMute => 'Без звуку';

  @override
  String get peerUnmute => 'Увімкнути звук';

  @override
  String get peerBlockedNote => 'Заблоковано — повідомлення відхиляються.';

  @override
  String get relaysTitle => 'Запасний канал через інтернет';

  @override
  String get relaysCardTitle => 'Досягати співрозмовників через інтернет';

  @override
  String get relaysCardSubtitle =>
      'Коли Bluetooth не доставляє — надсилати через релеї Nostr';

  @override
  String get relaysExplainer =>
      'Повідомлення лишаються наскрізно зашифрованими — релей несе той самий запечатаний кадр, що й Bluetooth. Але він бачить, які два ключі спілкуються і коли. Типово вимкнено.';

  @override
  String get relaysMyAddress => 'Ваша адреса на релеях';

  @override
  String get relaysCopied => 'Скопійовано';

  @override
  String get relaysListLabel => 'Релеї';

  @override
  String get relaysAdd => 'Додати релей';

  @override
  String get relaysAddHint => 'wss://relay.example.com';

  @override
  String get relaysInvalidUrl => 'Введіть адресу wss:// або ws://';

  @override
  String get relaysRemove => 'Видалити';

  @override
  String get relaysStateConnected => 'З\'єднано';

  @override
  String get relaysStateConnecting => 'З\'єднання…';

  @override
  String get relaysStateFailed => 'Недоступний';

  @override
  String get relaysStateIdle => 'Вимкнено';

  @override
  String get relaysEmpty => 'Релеї не налаштовані — запасний канал вимкнено.';
}
