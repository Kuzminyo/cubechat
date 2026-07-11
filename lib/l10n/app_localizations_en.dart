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
}
