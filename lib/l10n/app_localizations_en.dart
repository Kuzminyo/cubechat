// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Cubechat';

  @override
  String get navChats => 'Chats';

  @override
  String get navPeers => 'Nearby';

  @override
  String get navProfile => 'Profile';

  @override
  String get navContacts => 'Contacts';

  @override
  String get contactsTitle => 'Contacts';

  @override
  String get contactsSubtitle => 'Everyone you have messaged';

  @override
  String get contactsSearchHint => 'Search contacts…';

  @override
  String get contactsEmptyTitle => 'No contacts yet';

  @override
  String get contactsEmptyHint =>
      'Start a conversation and the person will appear here.';

  @override
  String get contactsSearchEmpty => 'No matching contacts';

  @override
  String get contactProfileChat => 'Chat';

  @override
  String get contactProfileSecurity => 'Security';

  @override
  String get contactProfileActions => 'Contact actions';

  @override
  String get contactProfileVerify => 'Verify';

  @override
  String get contactProfileCopyId => 'Copy contact ID';

  @override
  String get contactProfileIdCopied => 'Contact ID copied';

  @override
  String get contactProfileId => 'Contact ID';

  @override
  String get contactProfileVerifyHint =>
      'Compare encryption fingerprints to confirm this person.';

  @override
  String get chatsTitle => 'Chats';

  @override
  String get chatsSubtitle => 'Mesh · end-to-end encrypted';

  @override
  String get chatsEmptyTitle => 'No conversations yet';

  @override
  String get chatsEmptyHint =>
      'Open a peer from the Nearby tab to start chatting.';

  @override
  String get chatsFilterAll => 'All';

  @override
  String get chatsFilterUnread => 'Unread';

  @override
  String get chatsFilterMesh => 'Mesh';

  @override
  String get chatsFilterFavorites => 'Favorites';

  @override
  String get chatsFolderDirect => 'Direct';

  @override
  String get chatsFolderChannels => 'Channels';

  @override
  String get chatsFolderOnline => 'Reachable';

  @override
  String get chatsFoldersTitle => 'Folders';

  @override
  String get chatsFoldersHint =>
      'Folders are cuts of this list, not places chats are moved to. Switch on the ones you want above the chats.';

  @override
  String get chatsSearchHint => 'Search chats…';

  @override
  String get chatsStatusViaMesh => 'via mesh';

  @override
  String get chatsStatusOffline => 'offline';

  @override
  String get peerKeyRotated => 'key changed — re-verify';

  @override
  String get peersTitle => 'Nearby';

  @override
  String get peersSubtitle => 'Devices in Bluetooth range';

  @override
  String get peersEmpty => 'Looking for peers…';

  @override
  String peersHopsOne(int n) {
    return '$n hop away';
  }

  @override
  String peersHopsOther(int n) {
    return '$n hops away';
  }

  @override
  String get blePermissionTitle => 'Bluetooth permission needed';

  @override
  String get blePermissionHint =>
      'Cubechat needs Bluetooth to find peers and send messages — no internet required.';

  @override
  String get blePermissionGrant => 'Grant permission';

  @override
  String get blePermissionOpenSettings => 'Open settings';

  @override
  String get blePermissionDeniedHint =>
      'Permission was denied. Open settings to allow Bluetooth access.';

  @override
  String get bleAdapterOffTitle => 'Bluetooth is off';

  @override
  String get bleAdapterOffHint => 'Turn Bluetooth on to see peers nearby.';

  @override
  String get bleUnsupportedTitle => 'Bluetooth LE not available';

  @override
  String get bleUnsupportedHint =>
      'This device or platform doesn\'t expose Bluetooth Low Energy. Try it on a phone.';

  @override
  String get bleScanning => 'Scanning…';

  @override
  String get bleRetry => 'Retry';

  @override
  String get bleConnectFailed =>
      'Couldn\'t connect. The peer may be out of range, or its Bluetooth address changed.';

  @override
  String get bleSignal => 'Signal';

  @override
  String get bleConnect => 'Connect';

  @override
  String get bleConnected => 'Connected';

  @override
  String get bleVerified => 'Verified';

  @override
  String get bleUnknownPeer => 'Unidentified peer';

  @override
  String get bleBroadcasting => 'Broadcasting';

  @override
  String bleConnectedCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n centrals connected',
      one: '1 central connected',
      zero: 'No centrals',
    );
    return '$_temp0';
  }

  @override
  String get verifyTitle => 'Verify peer';

  @override
  String get verifyIntro =>
      'Compare these two fingerprints with your peer in person or over a voice call. If they match on both sides, you have confirmed the Noise handshake was not tampered with.';

  @override
  String get verifyMine => 'YOUR FINGERPRINT';

  @override
  String verifyTheirs(String name) {
    return '$name\'s FINGERPRINT';
  }

  @override
  String get verifyMarkAsVerified => 'Mark as verified';

  @override
  String get verifyAlreadyDone => 'This peer is verified.';

  @override
  String get verifyRevoke => 'Revoke';

  @override
  String verifyDoneSnack(String name) {
    return '$name marked as verified';
  }

  @override
  String get chatInputHint => 'Message';

  @override
  String get chatSend => 'Send';

  @override
  String get chatToday => 'Today';

  @override
  String get chatYesterday => 'Yesterday';

  @override
  String get chatDelivered => 'Delivered';

  @override
  String get chatRead => 'Read';

  @override
  String get chatSending => 'Sending';

  @override
  String get chatEncryptedNotice =>
      'Messages are end-to-end encrypted with the Noise Protocol.';

  @override
  String get chatSessionHandshaking => 'Establishing secure channel…';

  @override
  String get chatSessionEstablished => 'Secured · Noise XX';

  @override
  String get chatSessionFailed => 'Connection failed';

  @override
  String get presenceOnline => 'online';

  @override
  String get presenceOffline => 'offline';

  @override
  String get chatSessionFingerprintPending =>
      'Fingerprint will appear once the handshake completes.';

  @override
  String get chatEmptyEstablished =>
      'The secure channel is up. Send a message to start the conversation.';

  @override
  String get chatEmptyHandshaking =>
      'Waiting for the other side to finish the handshake…';

  @override
  String get profileTitle => 'Profile';

  @override
  String get profileNickname => 'Nickname';

  @override
  String get profileNicknameEditTitle => 'Set your nickname';

  @override
  String get profileNicknameHint => 'How others see you on the mesh';

  @override
  String get profileNicknameSave => 'Save';

  @override
  String get profileFingerprint => 'Public key fingerprint';

  @override
  String get profileLanguage => 'Language';

  @override
  String get profileLanguageEn => 'English';

  @override
  String get profileLanguageUk => 'Ukrainian';

  @override
  String get profileTransport => 'Transport';

  @override
  String get profileTransportMesh => 'Bluetooth mesh';

  @override
  String get profileBackground => 'Stay reachable in background';

  @override
  String get profileBackgroundSubtitle =>
      'Keep receiving messages while the app is closed';

  @override
  String get profileBatteryExempt => 'Disable battery optimisation';

  @override
  String get profileAbout => 'About';

  @override
  String profileVersion(String v) {
    return 'Version $v';
  }

  @override
  String get profileEmergencyWipe => 'Emergency wipe';

  @override
  String get profileEmergencyWipeHint =>
      'Triple-tap to erase all keys, peers, and messages.';

  @override
  String get profileEmergencyWipeConfirm => 'Erase everything?';

  @override
  String get profileEmergencyWipeConfirmHint =>
      'This will remove your identity, peer list, and conversation history. Cannot be undone.';

  @override
  String get profileEmergencyWipeAction => 'Erase';

  @override
  String get cancel => 'Cancel';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied';

  @override
  String get channelsNewTitle => 'New channel';

  @override
  String get channelsNewTooltip => 'New channel';

  @override
  String get channelNameLabel => 'Channel name';

  @override
  String get channelPasswordLabel => 'Password (optional)';

  @override
  String get channelJoinAction => 'Join';

  @override
  String get channelSubtitle => 'Group channel · shared key';

  @override
  String get chatsStatusChannel => 'channel';

  @override
  String get channelInviteTitle => 'Add people';

  @override
  String get channelInviteAction => 'Invite';

  @override
  String get channelInviteEmpty =>
      'No known peers yet. Meet someone on the Nearby tab first.';

  @override
  String get channelInviteSent => 'Invitations sent';

  @override
  String get channelInviteNoneSent => 'Nobody could be reached right now';

  @override
  String get channelNameTooLong => 'That channel name is too long';

  @override
  String get chatsActionFavorite => 'Add to favorites';

  @override
  String get chatsActionUnfavorite => 'Remove from favorites';

  @override
  String get chatsActionDelete => 'Delete chat';

  @override
  String get chatsDeleteTitle => 'Delete this chat?';

  @override
  String get chatsDeletePeerHint =>
      'Clears the conversation. The contact stays, so you can write to them again without swapping codes.';

  @override
  String get chatsDeleteChannelHint =>
      'Leaves the channel and removes its history. You will need the key again to rejoin.';

  @override
  String get chatsDeleteForThemToo => 'Also delete for them';

  @override
  String get chatsDeleteForThemHint =>
      'Asks their app to clear the whole conversation too, including what they wrote. In a channel, only your own messages are withdrawn.';

  @override
  String get chatEditAction => 'Edit';

  @override
  String get chatEditTitle => 'Edit message';

  @override
  String get chatEditSave => 'Save';

  @override
  String get chatEdited => 'edited';

  @override
  String get chatDeleteAction => 'Delete';

  @override
  String get chatDeleteTitle => 'Delete message?';

  @override
  String get chatDeleteForMe => 'Delete for me';

  @override
  String get chatDeleteForEveryone => 'Delete for everyone';

  @override
  String get chatReplyAction => 'Reply';

  @override
  String chatReplyingTo(String name) {
    return 'Replying to $name';
  }

  @override
  String get chatReplyYou => 'yourself';

  @override
  String get chatCopyAction => 'Copy';

  @override
  String get chatCopied => 'Copied';

  @override
  String get chatForwardAction => 'Forward';

  @override
  String get chatForwardTitle => 'Forward to';

  @override
  String get chatForwardEmpty => 'No other chats yet';

  @override
  String chatForwardSent(String name) {
    return 'Forwarded to $name';
  }

  @override
  String chatSentAt(String time) {
    return 'Sent $time';
  }

  @override
  String chatReadAt(String time) {
    return 'Read $time';
  }

  @override
  String get chatPinAction => 'Pin';

  @override
  String get chatUnpinAction => 'Unpin';

  @override
  String get chatUnpinConfirm => 'Unpin this message?';

  @override
  String get chatUnpinConfirmHint =>
      'It stops being pinned for everyone in this chat.';

  @override
  String get chatPinnedTitle => 'Pinned message';

  @override
  String get chatPinnedGone => 'That message is no longer in this chat';

  @override
  String get peerBlock => 'Block';

  @override
  String get peerUnblock => 'Unblock';

  @override
  String get peerMute => 'Mute';

  @override
  String get peerUnmute => 'Unmute';

  @override
  String get peerBlockedNote => 'Blocked — their messages are dropped.';

  @override
  String get relaysTitle => 'Internet fallback';

  @override
  String get relaysCardTitle => 'Reach peers over the internet';

  @override
  String get relaysCardSubtitle =>
      'When Bluetooth can\'t deliver, send via Nostr relays';

  @override
  String get relaysExplainer =>
      'Messages stay end-to-end encrypted — a relay only carries the same sealed frame Bluetooth would. It does learn which two keys are talking, and when. Off by default.';

  @override
  String get relaysMyAddress => 'Your relay address';

  @override
  String get relaysCopied => 'Copied';

  @override
  String get relaysListLabel => 'Relays';

  @override
  String get relaysAdd => 'Add relay';

  @override
  String get relaysAddHint => 'wss://relay.example.com';

  @override
  String get relaysInvalidUrl => 'Enter a wss:// or ws:// address';

  @override
  String get relaysRemove => 'Remove';

  @override
  String get relaysStateConnected => 'Connected';

  @override
  String get relaysStateConnecting => 'Connecting…';

  @override
  String get relaysStateFailed => 'Unreachable';

  @override
  String get relaysStateIdle => 'Off';

  @override
  String get relaysEmpty => 'No relays configured — the fallback stays off.';

  @override
  String get contactTitle => 'Contact card';

  @override
  String get contactMineLabel => 'Your card';

  @override
  String get contactMineExplainer =>
      'Send this to someone who is out of Bluetooth range. It carries your keys and your relay address — enough for them to start an encrypted chat with you over the internet.';

  @override
  String get contactCopy => 'Copy';

  @override
  String get contactShare => 'Share';

  @override
  String get contactCopied => 'Card copied';

  @override
  String get contactShareSubject => 'My cubechat contact card';

  @override
  String get contactAddLabel => 'Add someone';

  @override
  String get contactAddHint => 'Paste a contact card';

  @override
  String get contactAddAction => 'Add';

  @override
  String get contactPaste => 'Paste';

  @override
  String contactAdded(String name) {
    return 'Added $name';
  }

  @override
  String get contactInvalid => 'That isn\'t a valid contact card';

  @override
  String get contactOwnCard => 'That\'s your own card';

  @override
  String get contactUnverified =>
      'A contact added this way starts unverified. Anyone can mint a card and put any name on it, so compare fingerprints in person or over a call before you trust the identity.';

  @override
  String get contactRelayOff =>
      'Internet fallback is off, so a card can\'t reach anyone yet.';

  @override
  String get contactRelayEnable => 'Turn on';

  @override
  String get profileContactCard => 'Contact card';

  @override
  String get profileContactCardSubtitle =>
      'Chat with someone out of Bluetooth range';

  @override
  String get chatsAddContactTooltip => 'Add a contact by card';

  @override
  String get chatsMenuTooltip => 'More';

  @override
  String get chatsMenuAddContact => 'Add contact';

  @override
  String get chatsMenuNewChannel => 'New channel';

  @override
  String get profileDiscoverable => 'Discoverable nearby';

  @override
  String get profileDiscoverableOnHint => 'Anyone in range can find you';

  @override
  String get profileDiscoverableOffHint => 'Only your contacts can reach you';

  @override
  String get profileDiscoverableExplainer =>
      'On, your announcement is broadcast in the clear so strangers can meet you by walking up — and anyone listening records your key and name. Off, the same bundle goes only to contacts you already have, sealed, and your routing ids stay unlinkable. New people then need a contact card.';

  @override
  String get voiceHoldHint => 'Hold to record a voice message';

  @override
  String get voiceTrimPlay => 'Play';

  @override
  String get voiceTrimPause => 'Pause';

  @override
  String get voiceTrimDiscard => 'Discard recording';

  @override
  String voiceTrimSelection(String duration) {
    return 'Sending $duration';
  }

  @override
  String get profilePrivacy => 'Privacy';

  @override
  String get profileLastSeen => 'Share last seen';

  @override
  String get profileLastSeenOnHint =>
      'Contacts can see when you\'re in the app';

  @override
  String get profileLastSeenOffHint =>
      'Nobody sees yours — and you see nobody\'s';

  @override
  String get profileReadReceipts => 'Share read receipts';

  @override
  String get profileReadReceiptsOnHint => 'Senders see when you\'ve read them';

  @override
  String get profileReadReceiptsOffHint => 'They don\'t — and neither do you';

  @override
  String get profilePrivacyExplainer =>
      'Both switches cut both ways: hide your own status and you stop seeing everyone else\'s. Anything else would be a one-way mirror. Message delivery is untouched.';

  @override
  String get avatarSet => 'Choose a photo';

  @override
  String get avatarChange => 'Change photo';

  @override
  String get avatarRemove => 'Remove photo';

  @override
  String get avatarRemoveConfirm =>
      'The avatar will be deleted from this device. The generated gradient comes back in its place.';

  @override
  String get avatarFailed => 'Could not read that image';

  @override
  String get fileOpenHint => 'Tap to open';

  @override
  String get fileMissing => 'That file is no longer available';

  @override
  String get fileNoHandlerTitle => 'No app can open this';

  @override
  String get fileNoHandlerHint =>
      'Nothing installed handles this file type. You can send it to another app instead.';

  @override
  String get fileRequestedAgain => 'Asked the sender for it again';

  @override
  String get fileOpenFailed => 'Could not open this file';

  @override
  String get fileShareAction => 'Send to app';

  @override
  String fileTooLargeMesh(int limit) {
    return 'File is too large — $limit MB is the limit over the mesh';
  }

  @override
  String fileTooLargeRelay(int limit) {
    return 'Over the internet the limit is $limit MB. Get closer to the recipient to send a bigger file.';
  }

  @override
  String get mediaSendOriginal => 'Original';

  @override
  String get attachFile => 'File';

  @override
  String get attachGallery => 'Gallery';

  @override
  String get attachCamera => 'Camera';

  @override
  String get profileEditName => 'Name';

  @override
  String get profileMyCard => 'Card';

  @override
  String get mediaCaptionHint => 'Add a caption…';

  @override
  String get contactProfileAutoDelete => 'Auto-delete chat';

  @override
  String get contactProfileAutoDeleteTitle => 'Auto-delete messages';

  @override
  String get contactProfileAutoDeleteOff => 'Off';

  @override
  String get contactProfileAutoDeleteOneDay => 'After 1 day';

  @override
  String get contactProfileAutoDeleteSevenDays => 'After 7 days';

  @override
  String get contactProfileAutoDeleteThirtyDays => 'After 30 days';

  @override
  String contactProfileAutoDeleteUpdated(String period) {
    return 'Auto-delete: $period';
  }

  @override
  String get contactProfileShare => 'Share contact';

  @override
  String get contactProfileShareTitle => 'Send contact to';

  @override
  String get contactProfileShareEmpty => 'No other chats yet';

  @override
  String contactProfileShareSent(String name) {
    return 'Sent to $name';
  }

  @override
  String get contactProfileRestrictCopying => 'Disable copying';

  @override
  String get contactProfileAllowCopying => 'Allow copying';

  @override
  String get contactProfileCopyingRestricted =>
      'Copying and forwarding are disabled';

  @override
  String get contactProfileCopyingRestrictedByPeer =>
      'Disabled at the other end';

  @override
  String get contactProfileCopyingAllowed =>
      'Copying and forwarding are allowed';

  @override
  String get contactProfileDelete => 'Delete from contacts';

  @override
  String get contactProfileDeleteTitle => 'Remove contact?';

  @override
  String contactProfileDeleteMessage(String name) {
    return '$name will disappear from Contacts. Chat history stays on this device.';
  }

  @override
  String get contactProfileMedia => 'Media';

  @override
  String get contactProfileVoiceMessages => 'Voice messages';

  @override
  String get contactProfileNoMedia => 'No media yet';

  @override
  String get contactProfileNoVoiceMessages => 'No voice messages yet';

  @override
  String get contactProfileOpen => 'Open profile';

  @override
  String autoDeleteDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '$count day',
    );
    return '$_temp0';
  }

  @override
  String autoDeleteHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours',
      one: '$count hour',
    );
    return '$_temp0';
  }

  @override
  String autoDeleteMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '$count minute',
    );
    return '$_temp0';
  }

  @override
  String autoDeleteSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count seconds',
      one: '$count second',
    );
    return '$_temp0';
  }

  @override
  String get autoDeleteCustom => 'Custom…';

  @override
  String get autoDeleteCustomHint => 'Amount';

  @override
  String get autoDeleteUnitMinutes => 'min';

  @override
  String get autoDeleteUnitHours => 'hours';

  @override
  String get autoDeleteUnitDays => 'days';

  @override
  String get contactProfileAutoDeleteSet => 'Set';

  @override
  String get contactProfileFiles => 'Files';

  @override
  String get contactProfileNoFiles => 'No files yet';

  @override
  String get contactProfileLinks => 'Links';

  @override
  String get contactProfileNoLinks => 'No links yet';

  @override
  String get contactProfilePolls => 'Polls';

  @override
  String get contactProfileNoPolls => 'No polls yet';

  @override
  String get presenceHidden => 'status hidden';

  @override
  String chatReadByCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Read by $count',
      one: 'Read by $count',
    );
    return '$_temp0';
  }

  @override
  String get chatsSearchFrequent => 'People you talk to';

  @override
  String get chatsSearchRecent => 'Recent';

  @override
  String get chatsSearchClear => 'Clear';

  @override
  String get chatsSearchStartHint => 'Search your chats and channels by name.';

  @override
  String get chatsSearchEmpty => 'Nothing matches that';

  @override
  String get contactProfileViewInChat => 'View in chat';

  @override
  String get chatDraft => 'Draft';

  @override
  String get chatSearchTitle => 'Search';

  @override
  String get chatSearchHint => 'Search messages';

  @override
  String get chatSearchNoResults => 'No matches';

  @override
  String get chatSearchPrevious => 'Previous result';

  @override
  String get chatSearchNext => 'Next result';

  @override
  String chatMessageCount(int count) {
    return '$count messages';
  }

  @override
  String get chatRouteBluetooth => 'Bluetooth';

  @override
  String get chatRouteMesh => 'Mesh';

  @override
  String get chatRouteInternet => 'Internet';

  @override
  String get chatRouteQueued => 'Queued';

  @override
  String get chatAttachmentUnavailable =>
      'No connection is available. Connect over Bluetooth or the internet and try again.';

  @override
  String get fileTransfersTitle => 'File transfers';

  @override
  String get fileTransfersClear => 'Clear history';

  @override
  String get fileTransfersEmpty => 'No file transfers yet';

  @override
  String get fileTransfersActive => 'Active';

  @override
  String get fileTransfersHistory => 'History';

  @override
  String get fileTransferPause => 'Pause';

  @override
  String get fileTransferResume => 'Resume';

  @override
  String get fileTransferRetry => 'Retry';

  @override
  String get fileTransferQueued => 'Waiting for connection';

  @override
  String get fileTransferRunning => 'Transferring';

  @override
  String get fileTransferPaused => 'Paused';

  @override
  String get fileTransferCompleted => 'Completed';

  @override
  String get fileTransferFailed => 'Failed';

  @override
  String get fileTransferCanceled => 'Canceled';

  @override
  String get profileFileTransfers => 'File transfers';

  @override
  String get profileFileTransfersSubtitle =>
      'Progress, queue and transfer history';

  @override
  String get qrScanAction => 'Scan QR code';

  @override
  String get qrScanTitle => 'Scan QR code';

  @override
  String get qrScanHint =>
      'Point the camera at a Cubechat contact or channel QR code.';

  @override
  String get qrFlash => 'Flashlight';

  @override
  String get qrCameraError =>
      'Camera is unavailable. Check camera permission and try again.';

  @override
  String get qrInvalid => 'This is not a valid Cubechat QR code.';

  @override
  String qrChannelAdded(String name) {
    return '$name added';
  }

  @override
  String get qrShow => 'Show QR code';

  @override
  String qrChannelTitle(String name) {
    return 'Join $name';
  }

  @override
  String get profileBackup => 'Encrypted backup';

  @override
  String get profileBackupSubtitle => 'Move keys, contacts and history safely';

  @override
  String get backupTitle => 'Encrypted backup';

  @override
  String get backupExplainer =>
      'The backup contains your private identity keys, contacts, channels, settings and message history. It is encrypted on this phone with the password you choose; Cubechat cannot recover a forgotten password.';

  @override
  String get backupCreate => 'Create backup';

  @override
  String get backupCreateSubtitle =>
      'Encrypt everything and save a .cchatbackup file';

  @override
  String get backupRestore => 'Restore backup';

  @override
  String get backupRestoreSubtitle =>
      'Replace this phone’s Cubechat profile from a backup file';

  @override
  String get backupPasswordTitle => 'Backup password';

  @override
  String get backupPasswordHint => 'At least 8 characters';

  @override
  String get backupConfirmPassword => 'Repeat password';

  @override
  String get backupPasswordMismatch => 'Passwords do not match';

  @override
  String get backupPasswordShort => 'Use at least 8 characters';

  @override
  String get backupSaveTitle => 'Save Cubechat backup';

  @override
  String get backupSaved => 'Encrypted backup saved';

  @override
  String get backupFailed => 'Could not complete the backup operation';

  @override
  String get backupRestoreConfirmTitle => 'Replace this profile?';

  @override
  String get backupRestoreConfirmMessage =>
      'Current keys, contacts, channels, settings and history on this phone will be replaced by the selected backup.';

  @override
  String get backupRestoreConfirmAction => 'Restore';

  @override
  String get backupRestored => 'Backup restored';

  @override
  String get backupInvalid =>
      'Wrong password, damaged file, or unsupported backup';

  @override
  String get channelInfoTitle => 'Channel details';

  @override
  String get channelParticipantsTitle => 'Participants';

  @override
  String get channelAdministratorsTitle => 'Administrators';

  @override
  String get channelMakeAdmin => 'Make administrator';

  @override
  String get channelRemoveAdmin => 'Remove administrator';

  @override
  String get channelNoParticipants =>
      'Participants will appear after signed activity';

  @override
  String get channelSharedContent => 'Media, files and polls';

  @override
  String get channelDescriptionTitle => 'Description';

  @override
  String get channelDescriptionEmpty => 'No description yet';

  @override
  String get channelDescriptionHint => 'What this channel is for';

  @override
  String get channelDescriptionAdminOnly =>
      'Only an administrator can change the description';

  @override
  String get channelDescriptionSave => 'Save';

  @override
  String get chatTyping => 'typing…';

  @override
  String get onboardingMeshTitle => 'Works without internet';

  @override
  String get onboardingMeshBody =>
      'Messages travel over Bluetooth, phone to phone. No signal, no Wi-Fi, no accounts — just the people around you.';

  @override
  String get onboardingRelayTitle => 'And with it, when there is some';

  @override
  String get onboardingRelayBody =>
      'Out of Bluetooth range, messages take the internet instead and arrive the same way. You never pick which.';

  @override
  String get onboardingPrivacyTitle => 'Nobody in the middle can read it';

  @override
  String get onboardingPrivacyBody =>
      'Everything is end-to-end encrypted, and your identity is a key on this phone — not a phone number, not an email, not an account anyone can take away.';

  @override
  String get onboardingSkip => 'Skip';

  @override
  String get onboardingNext => 'Next';

  @override
  String get onboardingStart => 'Get started';

  @override
  String get chatMediaShare => 'Share';

  @override
  String get chatMediaSaveToGallery => 'Save to gallery';

  @override
  String get chatMediaShowInChat => 'Show in chat';

  @override
  String get chatWallpaperTitle => 'Wallpaper';

  @override
  String get chatWallpaperClear => 'Reset';

  @override
  String get chatWallpaperDim => 'Darken behind the messages';

  @override
  String get chatSelectAction => 'Select';

  @override
  String get chatForwardNothing => 'Nothing here can be forwarded';

  @override
  String chatSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selected',
      one: '1 selected',
    );
    return '$_temp0';
  }

  @override
  String chatDeleteSelectedTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count messages?',
      one: 'Delete this message?',
    );
    return '$_temp0';
  }

  @override
  String get contactAliasAction => 'Rename contact';

  @override
  String get contactAliasHint =>
      'Only you see this name. Leave empty to use theirs.';

  @override
  String get viewOnceSendLabel => 'View once';

  @override
  String get viewOnceTitle => 'View once';

  @override
  String get viewOnceTapToView => 'Photo · tap to view once';

  @override
  String get viewOnceSent => 'Photo · sent';

  @override
  String get viewOnceOpened => 'Photo opened';

  @override
  String get viewOnceUnavailable => 'This photo is no longer available';

  @override
  String get viewOnceWarning =>
      'Closing this deletes the photo for both of you.';

  @override
  String get channelAvatarAdminOnly =>
      'Only an administrator can change the channel photo';

  @override
  String get channelAdminOnly => 'Only an administrator can change this';

  @override
  String get channelAvatarTooLarge => 'That photo is too large to broadcast';

  @override
  String get channelMemberUnknown => 'Not in your contacts yet';

  @override
  String get channelPollTitle => 'Poll';

  @override
  String get channelCreatePoll => 'Create poll';

  @override
  String get channelPollQuestion => 'Question';

  @override
  String channelPollOption(int number) {
    return 'Option $number';
  }

  @override
  String get channelPollAddOption => 'Add option';

  @override
  String get channelPollCreate => 'Publish poll';

  @override
  String channelPollVotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count votes',
      one: '1 vote',
      zero: 'No votes',
    );
    return '$_temp0';
  }

  @override
  String get phoneTransferTitle => 'Transfer to a new phone';

  @override
  String get phoneTransferIntro =>
      'Move your profile, keys, contacts, channels, settings and history directly between two phones.';

  @override
  String get phoneTransferSend => 'This is the old phone';

  @override
  String get phoneTransferReceive => 'This is the new phone';

  @override
  String get phoneTransferSameWifi =>
      'Connect both phones to the same Wi-Fi. Keep this screen open until the transfer finishes.';

  @override
  String get phoneTransferPreparing => 'Preparing encrypted transfer…';

  @override
  String get phoneTransferReady => 'Scan this one-use QR code on the new phone';

  @override
  String get phoneTransferScan => 'Scan old phone';

  @override
  String get phoneTransferConfirmTitle => 'Replace this phone’s profile?';

  @override
  String get phoneTransferConfirmMessage =>
      'The profile currently stored on this phone will be replaced by the encrypted local transfer.';

  @override
  String get phoneTransferConfirmAction => 'Transfer profile';

  @override
  String get phoneTransferSuccess => 'Profile transferred successfully';

  @override
  String get phoneTransferFailed => 'Could not complete the phone transfer';

  @override
  String get profileGroupConnection => 'Connection';

  @override
  String get profileGroupPrivacy => 'Privacy';

  @override
  String get profileGroupData => 'Sharing & data';

  @override
  String get profileGroupApp => 'App';

  @override
  String get profileSummaryMeshOnly => 'Mesh only';

  @override
  String get profileSummaryMeshInternet => 'Mesh · internet';

  @override
  String get profileSummaryBackgroundOn => 'runs in background';

  @override
  String get profileSummaryDiscoverable => 'Discoverable';

  @override
  String get profileSummaryHidden => 'Hidden';

  @override
  String get profileSummaryLastSeenHidden => 'last seen hidden';

  @override
  String profileSummaryTransfersActive(int count) {
    return '$count in progress';
  }

  @override
  String get profileSummaryCardBackup => 'Contact card, files, backup';

  @override
  String get chatPlay => 'Play';

  @override
  String get chatPause => 'Pause';

  @override
  String get profileTheme => 'Colour';

  @override
  String get profileThemeEmerald => 'Emerald';

  @override
  String get profileThemeIndigo => 'Indigo';

  @override
  String get profileThemeAmber => 'Amber';

  @override
  String get profileThemeRose => 'Rose';

  @override
  String get profileThemeFuchsia => 'Fuchsia';

  @override
  String get profileThemeViolet => 'Violet';

  @override
  String get profileThemeOcean => 'Ocean';

  @override
  String get profileThemeSlate => 'Slate';

  @override
  String get profileScale => 'Interface size';

  @override
  String get profileScaleSystem => 'System';

  @override
  String get profileScaleSmall => 'Smaller';

  @override
  String get profileScaleNormal => 'Normal';

  @override
  String get profileScaleLarge => 'Larger';

  @override
  String get profileScaleSample => 'Text and rows are drawn at this size.';

  @override
  String get savedTitle => 'Saved';

  @override
  String get savedSubtitle => 'Notes to yourself, on this device';

  @override
  String get savedEmpty => 'Anything you write here stays on this phone.';

  @override
  String get meshOffTitle => 'Bluetooth mesh is off';

  @override
  String get meshOffHint =>
      'Nobody nearby can find you and you cannot find them. Messages still travel over the internet relay.';

  @override
  String get profileMeshSwitch => 'Bluetooth mesh';

  @override
  String get profileMeshSwitchHint =>
      'Find people nearby and carry messages without the internet. Off saves battery.';

  @override
  String get channelAdminOnlyHint =>
      'An announcement channel. Everyone still reads it.';
}
