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
      'Removes the conversation and forgets this peer. They can find you again over the mesh.';

  @override
  String get chatsDeleteChannelHint =>
      'Leaves the channel and removes its history. You will need the key again to rejoin.';

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
  String get fileTooLargeMesh =>
      'File is too large — 25 MB is the limit over the mesh';

  @override
  String get fileTooLargeRelay =>
      'Over the internet the limit is 3 MB. Get closer to the recipient to send a bigger file.';

  @override
  String get attachFile => 'File';

  @override
  String get attachGallery => 'Gallery';

  @override
  String get attachCamera => 'Camera';
}
