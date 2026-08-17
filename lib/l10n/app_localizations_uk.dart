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
  String get navMap => 'Мапа';

  @override
  String get mapTitle => 'Карта';

  @override
  String get mapFriendsTitle => 'Люди на мапі';

  @override
  String get mapFriendsHint => 'Лише ці контакти отримують вашу позицію';

  @override
  String mapClusterTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count людей тут',
      few: '$count людини тут',
      one: '$count людина тут',
    );
    return '$_temp0';
  }

  @override
  String get mapClusterHint => 'Торкніться, щоб мапа перейшла до людини';

  @override
  String get mapNorthUp => 'Повернути північ угору';

  @override
  String get mapLayerTitle => 'Вигляд мапи';

  @override
  String get mapLayerHint => 'На чому намальовані позначки';

  @override
  String get mapLayerDark => 'Темна';

  @override
  String get mapLayerDarkHint =>
      'Вулиці без написів — найтихіше тло під позначками';

  @override
  String get mapLayerSatellite => 'Супутник';

  @override
  String get mapLayerSatelliteHint =>
      'Знімки з висоти: який будинок, яке подвір’я';

  @override
  String get mapLayerTerrain => 'Рельєф';

  @override
  String get mapLayerTerrainHint => 'Горизонталі й рельєф — пагорби та стежки';

  @override
  String get mapFriendsEmpty => 'Ще ніхто не ділиться з вами мапою.';

  @override
  String get mapFriendsEmptyHint =>
      'Запросіть контакт — він з\'явиться тут, щойно прийме запрошення.';

  @override
  String get mapFriendsInvite => 'Запросити';

  @override
  String get mapFriendsRemove => 'Прибрати з мапи';

  @override
  String mapFriendsRemoved(String name) {
    return '$name більше не ділиться з вами мапою';
  }

  @override
  String get mapFriendsLive => 'Зараз на мапі';

  @override
  String get mapFriendsIdle => 'Позиції зараз немає';

  @override
  String get mapInviteTitle => 'Запросити на мапу';

  @override
  String get mapInviteHint => 'Оберіть один або кілька чатів';

  @override
  String get mapInviteEmpty => 'Поки немає чатів для запрошення.';

  @override
  String mapInviteAction(int count) {
    return 'Надіслати ($count)';
  }

  @override
  String get mapInviteMessage =>
      'Запрошення на мапу Cubechat. Надішліть свою геолокацію в цей чат, щоб з’явитися на мапі.';

  @override
  String mapInviteSent(int count) {
    return 'Надіслано запрошень: $count';
  }

  @override
  String get mapInviteFailed => 'Не вдалося надіслати запрошення';

  @override
  String mapPeopleVisible(int count) {
    return 'Спільних геолокацій: $count';
  }

  @override
  String get mapCenterMe => 'Центрувати на мені';

  @override
  String get mapNoSharedLocations => 'Поки немає геолокацій';

  @override
  String get mapNoSharedLocationsHint =>
      'Контакт з’явиться тут після того, як надішле геолокацію в чаті.';

  @override
  String get mapWebHintTitle => 'Зв’язки поблизу';

  @override
  String get mapWebHint =>
      'Лінії показують близькість, а не маршрут повідомлення.';

  @override
  String get mapOpenProfile => 'Профіль';

  @override
  String get mapLocationPrivacyOff => 'Геолокацію приховано';

  @override
  String get mapLocationPrivacyOffHint =>
      'Увімкніть «Показувати мене на мапі» у розділі «Приватність», щоб побачити свою точку.';

  @override
  String get mapYouOnMap => 'Вашу позицію видно на цьому пристрої';

  @override
  String get locationSharingDisabled =>
      'Спочатку увімкніть «Показувати мене на мапі» у розділі «Приватність».';

  @override
  String get mapLocationDenied => 'Доступ до геолокації вимкнено';

  @override
  String get mapLocationServiceOff => 'Увімкніть геолокацію, щоб показати себе';

  @override
  String get mapLocationUnavailable => 'Не вдалося визначити вашу позицію';

  @override
  String get mapDistanceUnknown => 'Відстань невідома';

  @override
  String mapDistanceMetres(int metres) {
    return '$metres м від вас';
  }

  @override
  String mapDistanceKilometres(String kilometres) {
    return '$kilometres км від вас';
  }

  @override
  String get mapUpdatedNow => 'щойно надіслано';

  @override
  String mapUpdatedMinutes(int minutes) {
    return 'надіслано $minutes хв тому';
  }

  @override
  String mapUpdatedHours(int hours) {
    return 'надіслано $hours год тому';
  }

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
  String get chatsFolderDirect => 'Особисті';

  @override
  String get chatsFolderChannels => 'Канали';

  @override
  String get chatsFolderOnline => 'На зв\'язку';

  @override
  String get chatsFoldersTitle => 'Папки';

  @override
  String get chatsFoldersHint =>
      'Папки — це зрізи цього ж списку, а не місця, куди переносять чати. Увімкніть ті, що потрібні над чатами.';

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
  String get bleEnable => 'Увімкнути';

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
      'Розмову буде очищено. Контакт залишиться — писати йому знову можна без обміну кодами.';

  @override
  String get chatsDeleteChannelHint =>
      'Ви вийдете з каналу та видалите його історію. Щоб повернутися, знадобиться ключ.';

  @override
  String get chatsDeleteForThemToo => 'Видалити і в співрозмовника';

  @override
  String get chatsDeleteForThemHint =>
      'Попросить його застосунок стерти всю розмову, разом з його власними повідомленнями. У каналі відкликаються лише ваші.';

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
  String get voiceHoldHint => 'Утримуйте, щоб записати голосове';

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
  String get profileLastSeenOffHint =>
      'Ваш час не бачить ніхто, і ви не бачите чужий — лише хто в мережі';

  @override
  String get profileMapLocation => 'Показувати мене на мапі';

  @override
  String get profileMapLocationOnHint =>
      'Геолокація доступна для ручного надсилання, а вашу точку показано на мапі';

  @override
  String get profileMapLocationOffHint =>
      'Застосунок не запитує геолокацію, а ваша точка прихована';

  @override
  String get profileReadReceipts => 'Показувати час прочитання';

  @override
  String get profileReadReceiptsOnHint => 'Відправник бачить, що ви прочитали';

  @override
  String get profileReadReceiptsOffHint =>
      'Ви не надсилаєте час прочитання, але бачите його від інших';

  @override
  String get profilePrivacyExplainer =>
      'Останній візит працює в обидва боки: сховавши свій статус, ви перестаєте бачити чужий. Час прочитання керує лише тим, що надсилаєте ви. На доставку повідомлень це не впливає — вони йдуть так само.';

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
  String get fileNoHandlerTitle => 'Немає застосунку для цього файлу';

  @override
  String get fileNoHandlerHint =>
      'Жоден встановлений застосунок не відкриває цей тип. Можна надіслати його в інший застосунок.';

  @override
  String get fileRequestedAgain => 'Попросили надіслати ще раз';

  @override
  String get fileOpenFailed => 'Не вдалося відкрити цей файл';

  @override
  String get fileShareAction => 'Надіслати в застосунок';

  @override
  String fileTooLargeMesh(int limit) {
    return 'Файл завеликий — максимум $limit МБ через мережу пристроїв';
  }

  @override
  String fileTooLargeRelay(int limit) {
    return 'Через інтернет можна надіслати до $limit МБ. Підійдіть ближче до співрозмовника, щоб надіслати більший файл.';
  }

  @override
  String get mediaSendOriginal => 'Оригінал';

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
  String get mediaDiscardTitle => 'Відхилити вибір?';

  @override
  String get mediaDiscardMessage =>
      'Закрити галерею та скасувати вибрані фото?';

  @override
  String get mediaDiscardConfirm => 'Відхилити';

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
  String get contactProfileCopyingRestrictedByPeer =>
      'Вимкнено співрозмовником';

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

  @override
  String autoDeleteDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count днів',
      few: '$count дні',
      one: '$count день',
    );
    return '$_temp0';
  }

  @override
  String autoDeleteHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count годин',
      few: '$count години',
      one: '$count година',
    );
    return '$_temp0';
  }

  @override
  String autoDeleteMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count хвилин',
      few: '$count хвилини',
      one: '$count хвилина',
    );
    return '$_temp0';
  }

  @override
  String autoDeleteSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count секунд',
      few: '$count секунди',
      one: '$count секунда',
    );
    return '$_temp0';
  }

  @override
  String get autoDeleteCustom => 'Свій варіант…';

  @override
  String get autoDeleteCustomHint => 'Кількість';

  @override
  String get autoDeleteUnitMinutes => 'хв';

  @override
  String get autoDeleteUnitHours => 'год';

  @override
  String get autoDeleteUnitDays => 'дні';

  @override
  String get contactProfileAutoDeleteSet => 'Встановити';

  @override
  String get contactProfileFiles => 'Файли';

  @override
  String get contactProfileNoFiles => 'Файлів ще немає';

  @override
  String get contactProfileLinks => 'Посилання';

  @override
  String get contactProfileNoLinks => 'Посилань ще немає';

  @override
  String get contactProfilePolls => 'Опитування';

  @override
  String get contactProfileNoPolls => 'Опитувань ще немає';

  @override
  String get presenceRecently => 'був(ла) нещодавно';

  @override
  String chatReadByCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Прочитали $count',
      few: 'Прочитали $count',
      one: 'Прочитав $count',
    );
    return '$_temp0';
  }

  @override
  String get chatsSearchFrequent => 'З ким ви спілкуєтесь';

  @override
  String get chatsSearchRecent => 'Недавні';

  @override
  String get chatsSearchClear => 'Очистити';

  @override
  String get chatsSearchStartHint => 'Шукайте чати та канали за назвою.';

  @override
  String get chatsSearchEmpty => 'Нічого не знайдено';

  @override
  String get contactProfileViewInChat => 'Переглянути в чаті';

  @override
  String get chatDraft => 'Чернетка';

  @override
  String get chatSearchTitle => 'Пошук';

  @override
  String get chatSearchHint => 'Пошук у повідомленнях';

  @override
  String get chatSearchNoResults => 'Нічого не знайдено';

  @override
  String get chatSearchPrevious => 'Попередній результат';

  @override
  String get chatSearchNext => 'Наступний результат';

  @override
  String chatMessageCount(int count) {
    return '$count повідомлень';
  }

  @override
  String get chatRouteBluetooth => 'Bluetooth';

  @override
  String get chatRouteMesh => 'Меш';

  @override
  String get chatRouteInternet => 'Інтернет';

  @override
  String get chatRouteQueued => 'У черзі';

  @override
  String get attachStickers => 'Стікери';

  @override
  String get stickersEmpty => 'Стікерів ще немає';

  @override
  String get stickersEmptyHint =>
      'Збережіть картинку з чату — і вона з\'явиться тут.';

  @override
  String get stickerKeep => 'Зберегти як стікер';

  @override
  String get stickerKept => 'Збережено у стікери';

  @override
  String get stickerForget => 'Видалити стікер';

  @override
  String get stickerCreate => 'Створити стікер з фото';

  @override
  String get stickerFailed => 'Не вдалося зробити стікер із цієї картинки';

  @override
  String get stickerLabel => 'Наліпка';

  @override
  String get previewPhoto => 'Фото';

  @override
  String get previewVoice => 'Голосове повідомлення';

  @override
  String get previewFile => 'Файл';

  @override
  String get stickerEmojiTitle => 'Оберіть емодзі для неї';

  @override
  String get stickersMine => 'Мої стікери';

  @override
  String get stickersStarterPack => 'Базовий набір';

  @override
  String get emojiTab => 'Емодзі';

  @override
  String get chatBlockedStatus => 'заблоковано';

  @override
  String get chatBlockedHint => 'Ви заблокували цю людину';

  @override
  String get chatRouteFallbackOff => 'Інтернет вимк.';

  @override
  String get chatAttachmentUnavailable =>
      'Немає доступного з\'єднання. Підключіться через Bluetooth або інтернет і спробуйте ще раз.';

  @override
  String get fileTransfersTitle => 'Центр передачі файлів';

  @override
  String get fileTransfersClear => 'Очистити історію';

  @override
  String get fileTransfersEmpty => 'Передач файлів ще немає';

  @override
  String get fileTransfersActive => 'Активні';

  @override
  String get fileTransfersHistory => 'Історія';

  @override
  String get fileTransferPause => 'Призупинити';

  @override
  String get fileTransferResume => 'Продовжити';

  @override
  String get fileTransferRetry => 'Повторити';

  @override
  String get fileTransferQueued => 'Очікує з’єднання';

  @override
  String get fileTransferRunning => 'Передавання';

  @override
  String get fileTransferPaused => 'Призупинено';

  @override
  String get fileTransferCompleted => 'Завершено';

  @override
  String get fileTransferFailed => 'Помилка';

  @override
  String get fileTransferCanceled => 'Скасовано';

  @override
  String get profileFileTransfers => 'Передача файлів';

  @override
  String get profileFileTransfersSubtitle =>
      'Прогрес, черга та історія передач';

  @override
  String get qrScanAction => 'Сканувати QR-код';

  @override
  String get qrScanTitle => 'Сканування QR-коду';

  @override
  String get qrScanHint =>
      'Наведіть камеру на QR-код контакту або каналу Cubechat.';

  @override
  String get qrFlash => 'Ліхтарик';

  @override
  String get qrCameraError =>
      'Камера недоступна. Перевірте дозвіл на камеру та спробуйте ще раз.';

  @override
  String get qrInvalid => 'Це недійсний QR-код Cubechat.';

  @override
  String qrChannelAdded(String name) {
    return '$name додано';
  }

  @override
  String get qrShow => 'Показати QR-код';

  @override
  String qrChannelTitle(String name) {
    return 'Приєднатися до $name';
  }

  @override
  String get profileBackup => 'Зашифрована резервна копія';

  @override
  String get profileBackupSubtitle =>
      'Безпечне перенесення ключів, контактів та історії';

  @override
  String get backupTitle => 'Зашифрована резервна копія';

  @override
  String get backupExplainer =>
      'Резервна копія містить приватні ключі профілю, контакти, канали, налаштування та історію повідомлень. Вона шифрується на цьому телефоні вибраним паролем; Cubechat не зможе відновити забутий пароль.';

  @override
  String get backupCreate => 'Створити копію';

  @override
  String get backupCreateSubtitle =>
      'Зашифрувати все та зберегти файл .cchatbackup';

  @override
  String get backupRestore => 'Відновити копію';

  @override
  String get backupRestoreSubtitle =>
      'Замінити профіль Cubechat на цьому телефоні даними з копії';

  @override
  String get backupPasswordTitle => 'Пароль резервної копії';

  @override
  String get backupPasswordHint => 'Щонайменше 8 символів';

  @override
  String get backupConfirmPassword => 'Повторіть пароль';

  @override
  String get backupPasswordMismatch => 'Паролі не збігаються';

  @override
  String get backupPasswordShort => 'Використайте щонайменше 8 символів';

  @override
  String get backupSaveTitle => 'Зберегти резервну копію Cubechat';

  @override
  String get backupSaved => 'Зашифровану копію збережено';

  @override
  String get backupFailed => 'Не вдалося завершити операцію з резервною копією';

  @override
  String get backupRestoreConfirmTitle => 'Замінити цей профіль?';

  @override
  String get backupRestoreConfirmMessage =>
      'Поточні ключі, контакти, канали, налаштування та історію на цьому телефоні буде замінено вибраною резервною копією.';

  @override
  String get backupRestoreConfirmAction => 'Відновити';

  @override
  String get backupRestored => 'Резервну копію відновлено';

  @override
  String get backupInvalid =>
      'Неправильний пароль, пошкоджений файл або непідтримувана копія';

  @override
  String get channelInfoTitle => 'Про канал';

  @override
  String get channelParticipantsTitle => 'Учасники';

  @override
  String get channelAdministratorsTitle => 'Адміністратори';

  @override
  String get channelMakeAdmin => 'Зробити адміністратором';

  @override
  String get channelRemoveAdmin => 'Забрати права адміністратора';

  @override
  String get channelNoParticipants =>
      'Учасники з’являться після підписаної активності';

  @override
  String get channelSharedContent => 'Медіа, файли та опитування';

  @override
  String get channelDescriptionTitle => 'Опис';

  @override
  String get channelDescriptionEmpty => 'Опису ще немає';

  @override
  String get channelDescriptionHint => 'Для чого цей канал';

  @override
  String get channelDescriptionAdminOnly =>
      'Змінювати опис може лише адміністратор';

  @override
  String get channelDescriptionSave => 'Зберегти';

  @override
  String get chatTyping => 'пише…';

  @override
  String get onboardingMeshTitle => 'Працює без інтернету';

  @override
  String get onboardingMeshBody =>
      'Повідомлення йдуть через Bluetooth, від телефона до телефона. Без зв’язку, без Wi-Fi, без акаунтів — лише люди поруч.';

  @override
  String get onboardingRelayTitle => 'І з ним, коли він є';

  @override
  String get onboardingRelayBody =>
      'Поза зоною Bluetooth повідомлення йдуть інтернетом і доходять так само. Вам не треба обирати.';

  @override
  String get onboardingPrivacyTitle => 'Ніхто посередині не прочитає';

  @override
  String get onboardingPrivacyBody =>
      'Усе зашифровано наскрізно, а ваша особистість — це ключ на цьому телефоні: не номер, не пошта, не акаунт, який хтось може відібрати.';

  @override
  String get onboardingSkip => 'Пропустити';

  @override
  String get onboardingNext => 'Далі';

  @override
  String get onboardingStart => 'Почати';

  @override
  String get chatMediaShare => 'Поділитися';

  @override
  String get chatMediaSaveToGallery => 'Зберегти в галерею';

  @override
  String get chatMediaShowInChat => 'Показати в чаті';

  @override
  String get chatWallpaperTitle => 'Шпалери';

  @override
  String get chatWallpaperClear => 'Скинути';

  @override
  String get chatWallpaperDim => 'Затемнення під повідомленнями';

  @override
  String get chatSelectAction => 'Вибрати';

  @override
  String get chatForwardNothing => 'Тут немає чого переслати';

  @override
  String chatSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Вибрано $count',
      many: 'Вибрано $count',
      few: 'Вибрано $count',
      one: 'Вибрано 1',
    );
    return '$_temp0';
  }

  @override
  String chatDeleteSelectedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Видалити $count повідомлення?',
      many: 'Видалити $count повідомлень?',
      few: 'Видалити $count повідомлення?',
      one: 'Видалити це повідомлення?',
    );
    return '$_temp0';
  }

  @override
  String get contactAliasAction => 'Перейменувати контакт';

  @override
  String get contactAliasHint =>
      'Це ім’я бачите лише ви. Порожньо — буде їхнє.';

  @override
  String get viewOnceSendLabel => 'Один перегляд';

  @override
  String get viewOnceTitle => 'Один перегляд';

  @override
  String get viewOnceTapToView => 'Фото · торкніться, щоб переглянути раз';

  @override
  String get viewOnceSent => 'Фото · надіслано';

  @override
  String get viewOnceOpened => 'Фото переглянуто';

  @override
  String get viewOnceUnavailable => 'Це фото більше недоступне';

  @override
  String get viewOnceWarning => 'Після виходу фото буде видалено в обох.';

  @override
  String get channelAvatarAdminOnly =>
      'Змінювати фото каналу може лише адміністратор';

  @override
  String get channelAdminOnly => 'Змінювати це може лише адміністратор';

  @override
  String get channelAvatarTooLarge => 'Це фото завелике для розсилки';

  @override
  String get channelMemberUnknown => 'Ще не у ваших контактах';

  @override
  String get channelInviteToContacts => 'Надіслати свою картку контакту';

  @override
  String channelContactInviteSent(String name) {
    return 'Картку контакту надіслано $name';
  }

  @override
  String get chatContactInvitation => 'Запрошення додати контакт';

  @override
  String get chatContactInvitationForYou => 'Запрошення для вас';

  @override
  String get channelPollTitle => 'Опитування';

  @override
  String get channelCreatePoll => 'Створити опитування';

  @override
  String get channelPollQuestion => 'Запитання';

  @override
  String channelPollOption(int number) {
    return 'Варіант $number';
  }

  @override
  String get channelPollAddOption => 'Додати варіант';

  @override
  String get channelPollCreate => 'Опублікувати';

  @override
  String channelPollVotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count голосу',
      many: '$count голосів',
      few: '$count голоси',
      one: '1 голос',
      zero: 'Немає голосів',
    );
    return '$_temp0';
  }

  @override
  String get phoneTransferTitle => 'Перенесення на новий телефон';

  @override
  String get phoneTransferIntro =>
      'Перенесіть профіль, ключі, контакти, канали, налаштування та історію напряму між двома телефонами.';

  @override
  String get phoneTransferSend => 'Це старий телефон';

  @override
  String get phoneTransferReceive => 'Це новий телефон';

  @override
  String get phoneTransferSameWifi =>
      'Під’єднайте обидва телефони до однієї Wi-Fi мережі й не закривайте цей екран до завершення.';

  @override
  String get phoneTransferPreparing => 'Готуємо зашифроване перенесення…';

  @override
  String get phoneTransferReady =>
      'Відскануйте цей одноразовий QR-код на новому телефоні';

  @override
  String get phoneTransferScan => 'Сканувати старий телефон';

  @override
  String get phoneTransferConfirmTitle => 'Замінити профіль на цьому телефоні?';

  @override
  String get phoneTransferConfirmMessage =>
      'Поточний профіль на цьому телефоні буде замінено даними із зашифрованого локального перенесення.';

  @override
  String get phoneTransferConfirmAction => 'Перенести профіль';

  @override
  String get phoneTransferSuccess => 'Профіль успішно перенесено';

  @override
  String get phoneTransferFailed => 'Не вдалося завершити перенесення телефону';

  @override
  String get profileGroupConnection => 'З\'єднання';

  @override
  String get profileGroupPrivacy => 'Приватність';

  @override
  String get profileGroupData => 'Обмін і дані';

  @override
  String get profileGroupApp => 'Застосунок';

  @override
  String get profileSummaryMeshOnly => 'Тільки mesh';

  @override
  String get profileSummaryMeshInternet => 'Mesh · інтернет';

  @override
  String get profileSummaryBackgroundOn => 'працює у фоні';

  @override
  String get profileSummaryDiscoverable => 'Вас видно';

  @override
  String get profileSummaryHidden => 'Приховано';

  @override
  String get profileSummaryLastSeenHidden => 'час у мережі приховано';

  @override
  String get profileSummaryMapHidden => 'геолокацію приховано';

  @override
  String profileSummaryTransfersActive(int count) {
    return '$count у процесі';
  }

  @override
  String get profileSummaryCardBackup => 'Картка, файли, бекап';

  @override
  String get chatPlay => 'Відтворити';

  @override
  String get chatPause => 'Пауза';

  @override
  String get profileTheme => 'Колір';

  @override
  String get profileThemeEmerald => 'Смарагд';

  @override
  String get profileThemeIndigo => 'Індиго';

  @override
  String get profileThemeAmber => 'Бурштин';

  @override
  String get profileThemeRose => 'Троянда';

  @override
  String get profileThemeFuchsia => 'Фуксія';

  @override
  String get profileThemeViolet => 'Фіалка';

  @override
  String get profileThemeOcean => 'Океан';

  @override
  String get profileThemeSlate => 'Графіт';

  @override
  String get profileScale => 'Розмір інтерфейсу';

  @override
  String get profileScaleSystem => 'Системний';

  @override
  String get profileScaleSmall => 'Менший';

  @override
  String get profileScaleNormal => 'Звичайний';

  @override
  String get profileScaleLarge => 'Більший';

  @override
  String get profileScaleSample => 'Текст і рядки малюються цього розміру.';

  @override
  String get savedTitle => 'Збережені';

  @override
  String get savedSubtitle => 'Нотатки для себе, на цьому пристрої';

  @override
  String get savedEmpty =>
      'Усе, що ви тут напишете, залишиться на цьому телефоні.';

  @override
  String get meshOffTitle => 'Bluetooth-мережу вимкнено';

  @override
  String get meshOffHint =>
      'Ніхто поруч вас не знайде, і ви їх теж. Повідомлення й далі йдуть через інтернет-реле.';

  @override
  String get profileMeshSwitch => 'Bluetooth-мережа';

  @override
  String get profileMeshSwitchHint =>
      'Знаходить людей поруч і передає повідомлення без інтернету. Вимкнено — економить батарею.';

  @override
  String get channelAdminOnlyHint => 'Канал оголошень. Читати можуть усі.';

  @override
  String get attachLocation => 'Геолокація';

  @override
  String get locationBubbleTitle => 'Геолокація';

  @override
  String get locationOpenInMaps => 'Відкрити в картах';

  @override
  String locationAccuracy(int metres) {
    return 'з точністю до $metres м';
  }

  @override
  String get locationExpired => 'Ця геолокація вже не актуальна';

  @override
  String get locationDenied => 'Доступ до геолокації вимкнено';

  @override
  String get locationUnavailable => 'Не вдалося визначити місце';

  @override
  String get locationShareFor => 'Поділитися на';

  @override
  String get locationShareOnce => 'Разово';

  @override
  String get locationShare15m => '15 хвилин';

  @override
  String get locationShare1h => '1 година';

  @override
  String get storageTitle => 'Пам\'ять';

  @override
  String get storageHeadline => 'Використання пам\'яті';

  @override
  String storageSubtitle(String size) {
    return 'cubechat займає $size на цьому пристрої';
  }

  @override
  String get storageEmpty => 'Поки нічого не збережено';

  @override
  String get storageScanning => 'Рахую…';

  @override
  String get storageCatPhotos => 'Фото';

  @override
  String get storageCatVoice => 'Голосові';

  @override
  String get storageCatFiles => 'Отримані файли';

  @override
  String get storageCatOutbox => 'Надіслані файли';

  @override
  String get storageCatStickers => 'Наліпки';

  @override
  String get storageCatSaved => 'Збережене';

  @override
  String get storageCatWallpapers => 'Шпалери';

  @override
  String get storageCatHistory => 'Листування та ключі';

  @override
  String get storageCatCache => 'Кеш';

  @override
  String storageClear(String size) {
    return 'Очистити $size';
  }

  @override
  String get storageClearNothing => 'Нічого не вибрано';

  @override
  String storageFreed(String size) {
    return 'Звільнено $size';
  }

  @override
  String get storageNoCloud =>
      'Тут немає хмари. Усе, що ви очистите, зникне з цього телефона, і єдина інша копія — на телефоні, звідки воно прийшло.';

  @override
  String get storageWhyHistoryLocked =>
      'Листування звідси не очищується — для цього є Екстрене стирання.';

  @override
  String get storageRecoveryFree => 'Безпечно очищати';

  @override
  String get storageRecoveryGone => 'Копії більше ніде немає';

  @override
  String get storageRecoveryAskSender => 'Можна запросити у відправника знову';

  @override
  String get storageRecoveryCostsThem =>
      'Вони більше не зможуть попросити надіслати повторно';

  @override
  String storageConfirmTitle(String size) {
    return 'Очистити $size?';
  }

  @override
  String get storageConfirmBody =>
      'Файли буде видалено з цього телефона. Нікуди нічого не вивантажується, тож відновлювати їх немає звідки.';

  @override
  String storageFilesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count файла',
      many: '$count файлів',
      few: '$count файли',
      one: '$count файл',
      zero: 'порожньо',
    );
    return '$_temp0';
  }

  @override
  String get profileGroupCustomize => 'Кастомізація';

  @override
  String get customizeTitle => 'Кастомізація';

  @override
  String get customizeBarTitle => 'Нижня панель';

  @override
  String get customizeBarHint =>
      'Перетягніть, щоб змінити порядок. Чати прибрати не можна.';

  @override
  String get customizeBarShown => 'Показані';

  @override
  String get customizeBarHidden => 'Приховані';

  @override
  String get customizeBarHiddenEmpty => 'Нічого не приховано';

  @override
  String get customizeBarMinimum => 'Лишіть щонайменше дві вкладки';

  @override
  String get customizeReset => 'Повернути як було';

  @override
  String get chatsArchiveTitle => 'Архів';

  @override
  String get chatsArchiveEmpty => 'Архів порожній';

  @override
  String get chatsArchiveHint =>
      'Архівні чати працюють як звичайні — вони просто не в списку.';

  @override
  String get chatsArchivedToast => 'В архіві';

  @override
  String get chatsUnarchivedToast => 'Повернуто до списку';

  @override
  String chatsArchiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count чату',
      many: '$count чатів',
      few: '$count чати',
      one: '$count чат',
    );
    return '$_temp0';
  }

  @override
  String get chatsSwipeNotHere => 'Для цього чату недоступно';

  @override
  String get customizeSwipeTitle => 'Свайп чату вправо';

  @override
  String get customizeSwipeHint => 'Свайп вліво так само гортає вкладки.';

  @override
  String get customizeSwipeArchive => 'В архів';

  @override
  String get customizeSwipeMute => 'Без звуку';

  @override
  String get customizeSwipePin => 'Закріпити';

  @override
  String get customizeSwipeRead => 'Прочитано';

  @override
  String get customizeSwipeDelete => 'Видалити';

  @override
  String get customizeSwipeNone => 'Нічого';

  @override
  String get customizeQuickReaction => 'Реакція подвійним тапом';

  @override
  String get customizeQuickReactionHint =>
      'Що залишає подвійний тап на повідомленні. Якщо скористатися іншою — вона стане тут.';

  @override
  String get previewReacted => 'на ваше повідомлення';

  @override
  String get previewLocation => 'Геолокація';

  @override
  String get previewMapInvite => 'Запрошення на мапу';

  @override
  String get previewContact => 'Контакт';

  @override
  String get previewUnsupported => 'Повідомлення не підтримується';

  @override
  String chatPreparingPhotos(int count) {
    return 'Готую $count фото…';
  }
}
