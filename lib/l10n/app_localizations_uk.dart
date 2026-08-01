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
  String get navContacts => 'Контакти';

  @override
  String get contactsTitle => 'Контакти';

  @override
  String get contactsSubtitle => 'Усі, з ким ви вже листувалися';

  @override
  String get contactsSearchHint => 'Пошук контактів…';

  @override
  String get contactsEmptyTitle => 'Поки що немає контактів';

  @override
  String get contactsEmptyHint =>
      'Почніть розмову — і співрозмовник з’явиться тут.';

  @override
  String get contactsSearchEmpty => 'Контактів не знайдено';

  @override
  String get contactProfileChat => 'Чат';

  @override
  String get contactProfileSecurity => 'Безпека';

  @override
  String get contactProfileActions => 'Дії контакту';

  @override
  String get contactProfileVerify => 'Підтвердити';

  @override
  String get contactProfileCopyId => 'Копіювати ID контакту';

  @override
  String get contactProfileIdCopied => 'ID контакту скопійовано';

  @override
  String get contactProfileId => 'ID контакту';

  @override
  String get contactProfileVerifyHint =>
      'Порівняйте відбитки шифрування, щоб підтвердити цю особу.';

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
  String chatSentAt(String time) {
    return 'Надіслано $time';
  }

  @override
  String chatReadAt(String time) {
    return 'Прочитано $time';
  }

  @override
  String get chatPinAction => 'Закріпити';

  @override
  String get chatUnpinAction => 'Відкріпити';

  @override
  String get chatUnpinConfirm => 'Відкріпити це повідомлення?';

  @override
  String get chatUnpinConfirmHint =>
      'Воно перестане бути закріпленим для всіх у цьому чаті.';

  @override
  String get chatPinnedTitle => 'Закріплене повідомлення';

  @override
  String get chatPinnedGone => 'Цього повідомлення вже немає в чаті';

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

  @override
  String get contactTitle => 'Картка контакту';

  @override
  String get contactMineLabel => 'Ваша картка';

  @override
  String get contactMineExplainer =>
      'Надішліть її тому, хто поза зоною Bluetooth. Вона містить ваші ключі та адресу на релеях — цього досить, щоб почати з вами зашифрований чат через інтернет.';

  @override
  String get contactCopy => 'Копіювати';

  @override
  String get contactShare => 'Поділитися';

  @override
  String get contactCopied => 'Картку скопійовано';

  @override
  String get contactShareSubject => 'Моя картка контакту cubechat';

  @override
  String get contactAddLabel => 'Додати людину';

  @override
  String get contactAddHint => 'Вставте картку контакту';

  @override
  String get contactAddAction => 'Додати';

  @override
  String get contactPaste => 'Вставити';

  @override
  String contactAdded(String name) {
    return 'Додано $name';
  }

  @override
  String get contactInvalid => 'Це не картка контакту';

  @override
  String get contactOwnCard => 'Це ваша власна картка';

  @override
  String get contactUnverified =>
      'Доданий так контакт спершу неперевірений. Будь-хто може створити картку й написати на ній будь-яке ім\'я, тож звірте відбитки особисто або по дзвінку, перш ніж довіряти особі.';

  @override
  String get contactRelayOff =>
      'Запасний канал через інтернет вимкнено, тож картка поки нікого не досягне.';

  @override
  String get contactRelayEnable => 'Увімкнути';

  @override
  String get profileContactCard => 'Картка контакту';

  @override
  String get profileContactCardSubtitle =>
      'Спілкування з тим, хто поза зоною Bluetooth';

  @override
  String get chatsAddContactTooltip => 'Додати контакт за карткою';

  @override
  String get chatsMenuTooltip => 'Ще';

  @override
  String get chatsMenuAddContact => 'Додати контакт';

  @override
  String get chatsMenuNewChannel => 'Новий канал';

  @override
  String get profileDiscoverable => 'Помітність поруч';

  @override
  String get profileDiscoverableOnHint => 'Вас знайде будь-хто в радіусі';

  @override
  String get profileDiscoverableOffHint => 'Вас досягнуть лише ваші контакти';

  @override
  String get profileDiscoverableExplainer =>
      'Увімкнено — ваш анонс іде відкрито, тож незнайомець може познайомитися, просто підійшовши, але й будь-хто поруч запише ваш ключ та ім\'я. Вимкнено — той самий набір іде лише наявним контактам, запечатаним, а ваші маршрутні ID лишаються незв\'язними. Новим людям тоді потрібна картка контакту.';

  @override
  String get voiceTrimPlay => 'Відтворити';

  @override
  String get voiceTrimPause => 'Пауза';

  @override
  String get voiceTrimDiscard => 'Видалити запис';

  @override
  String voiceTrimSelection(String duration) {
    return 'Надсилаємо $duration';
  }

  @override
  String get profilePrivacy => 'Приватність';

  @override
  String get profileLastSeen => 'Показувати час у мережі';

  @override
  String get profileLastSeenOnHint => 'Контакти бачать, коли ви в застосунку';

  @override
  String get profileLastSeenOffHint => 'Ніхто не бачить — і ви теж не бачите';

  @override
  String get profileReadReceipts => 'Показувати час прочитання';

  @override
  String get profileReadReceiptsOnHint => 'Відправник бачить, що ви прочитали';

  @override
  String get profileReadReceiptsOffHint => 'Не бачить — і ви не бачите його';

  @override
  String get profilePrivacyExplainer =>
      'Обидва перемикачі працюють в обидва боки: сховавши свій статус, ви перестаєте бачити чужий. Інакше вийшло б одностороннє дзеркало. На доставку повідомлень це не впливає — вони йдуть так само.';

  @override
  String get avatarSet => 'Обрати фото';

  @override
  String get avatarChange => 'Змінити фото';

  @override
  String get avatarRemove => 'Прибрати фото';

  @override
  String get avatarRemoveConfirm =>
      'Аватарку буде видалено з цього пристрою. Замість неї повернеться згенерований градієнт.';

  @override
  String get avatarFailed => 'Не вдалося прочитати зображення';

  @override
  String get fileOpenHint => 'Торкніться, щоб відкрити';

  @override
  String get fileMissing => 'Файл більше недоступний';

  @override
  String get fileTooLargeMesh =>
      'Файл завеликий — максимум 25 МБ через мережу пристроїв';

  @override
  String get fileTooLargeRelay =>
      'Через інтернет можна надіслати до 3 МБ. Підійдіть ближче до співрозмовника, щоб надіслати більший файл.';

  @override
  String get attachFile => 'Файл';

  @override
  String get attachGallery => 'Галерея';

  @override
  String get attachCamera => 'Камера';

  @override
  String get profileEditName => 'Ім\'я';

  @override
  String get profileMyCard => 'Картка';

  @override
  String get mediaCaptionHint => 'Додати підпис…';

  @override
  String get contactProfileAutoDelete => 'Автоочищення чату';

  @override
  String get contactProfileAutoDeleteTitle => 'Автовидалення повідомлень';

  @override
  String get contactProfileAutoDeleteOff => 'Вимкнено';

  @override
  String get contactProfileAutoDeleteOneDay => 'Через 1 день';

  @override
  String get contactProfileAutoDeleteSevenDays => 'Через 7 днів';

  @override
  String get contactProfileAutoDeleteThirtyDays => 'Через 30 днів';

  @override
  String contactProfileAutoDeleteUpdated(String period) {
    return 'Автоочищення: $period';
  }

  @override
  String get contactProfileShare => 'Поділитися контактом';

  @override
  String get contactProfileShareTitle => 'Надіслати контакт до';

  @override
  String get contactProfileShareEmpty => 'Інших чатів ще немає';

  @override
  String contactProfileShareSent(String name) {
    return 'Надіслано до $name';
  }

  @override
  String get contactProfileRestrictCopying => 'Заборонити копіювання';

  @override
  String get contactProfileAllowCopying => 'Дозволити копіювання';

  @override
  String get contactProfileCopyingRestricted =>
      'Копіювання і пересилання вимкнено';

  @override
  String get contactProfileCopyingAllowed =>
      'Копіювання і пересилання дозволено';

  @override
  String get contactProfileDelete => 'Видалити з контактів';

  @override
  String get contactProfileDeleteTitle => 'Видалити контакт?';

  @override
  String contactProfileDeleteMessage(String name) {
    return '$name зникне з розділу «Контакти». Історія чату залишиться на цьому пристрої.';
  }

  @override
  String get contactProfileMedia => 'Медіа';

  @override
  String get contactProfileVoiceMessages => 'Голосові повідомлення';

  @override
  String get contactProfileNoMedia => 'Медіа ще немає';

  @override
  String get contactProfileNoVoiceMessages => 'Голосових повідомлень ще немає';

  @override
  String get contactProfileOpen => 'Відкрити профіль';
}
