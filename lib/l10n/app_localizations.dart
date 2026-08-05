import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_uk.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('uk')
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Cubechat'**
  String get appName;

  /// No description provided for @navChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get navChats;

  /// No description provided for @navPeers.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get navPeers;

  /// No description provided for @navProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get navProfile;

  /// No description provided for @navContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get navContacts;

  /// No description provided for @contactsTitle.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get contactsTitle;

  /// No description provided for @contactsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Everyone you have messaged'**
  String get contactsSubtitle;

  /// No description provided for @contactsSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search contacts…'**
  String get contactsSearchHint;

  /// No description provided for @contactsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No contacts yet'**
  String get contactsEmptyTitle;

  /// No description provided for @contactsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation and the person will appear here.'**
  String get contactsEmptyHint;

  /// No description provided for @contactsSearchEmpty.
  ///
  /// In en, this message translates to:
  /// **'No matching contacts'**
  String get contactsSearchEmpty;

  /// No description provided for @contactProfileChat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get contactProfileChat;

  /// No description provided for @contactProfileSecurity.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get contactProfileSecurity;

  /// No description provided for @contactProfileActions.
  ///
  /// In en, this message translates to:
  /// **'Contact actions'**
  String get contactProfileActions;

  /// No description provided for @contactProfileVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get contactProfileVerify;

  /// No description provided for @contactProfileCopyId.
  ///
  /// In en, this message translates to:
  /// **'Copy contact ID'**
  String get contactProfileCopyId;

  /// No description provided for @contactProfileIdCopied.
  ///
  /// In en, this message translates to:
  /// **'Contact ID copied'**
  String get contactProfileIdCopied;

  /// No description provided for @contactProfileId.
  ///
  /// In en, this message translates to:
  /// **'Contact ID'**
  String get contactProfileId;

  /// No description provided for @contactProfileVerifyHint.
  ///
  /// In en, this message translates to:
  /// **'Compare encryption fingerprints to confirm this person.'**
  String get contactProfileVerifyHint;

  /// No description provided for @chatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatsTitle;

  /// No description provided for @chatsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Mesh · end-to-end encrypted'**
  String get chatsSubtitle;

  /// No description provided for @chatsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get chatsEmptyTitle;

  /// No description provided for @chatsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Open a peer from the Nearby tab to start chatting.'**
  String get chatsEmptyHint;

  /// No description provided for @chatsFilterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get chatsFilterAll;

  /// No description provided for @chatsFilterUnread.
  ///
  /// In en, this message translates to:
  /// **'Unread'**
  String get chatsFilterUnread;

  /// No description provided for @chatsFilterMesh.
  ///
  /// In en, this message translates to:
  /// **'Mesh'**
  String get chatsFilterMesh;

  /// No description provided for @chatsFilterFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get chatsFilterFavorites;

  /// No description provided for @chatsFolderDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get chatsFolderDirect;

  /// No description provided for @chatsFolderChannels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get chatsFolderChannels;

  /// No description provided for @chatsFolderOnline.
  ///
  /// In en, this message translates to:
  /// **'Reachable'**
  String get chatsFolderOnline;

  /// No description provided for @chatsFoldersTitle.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get chatsFoldersTitle;

  /// No description provided for @chatsFoldersHint.
  ///
  /// In en, this message translates to:
  /// **'Folders are cuts of this list, not places chats are moved to. Switch on the ones you want above the chats.'**
  String get chatsFoldersHint;

  /// No description provided for @chatsSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search chats…'**
  String get chatsSearchHint;

  /// No description provided for @chatsStatusViaMesh.
  ///
  /// In en, this message translates to:
  /// **'via mesh'**
  String get chatsStatusViaMesh;

  /// No description provided for @chatsStatusOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get chatsStatusOffline;

  /// No description provided for @peerKeyRotated.
  ///
  /// In en, this message translates to:
  /// **'key changed — re-verify'**
  String get peerKeyRotated;

  /// No description provided for @peersTitle.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get peersTitle;

  /// No description provided for @peersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Devices in Bluetooth range'**
  String get peersSubtitle;

  /// No description provided for @peersEmpty.
  ///
  /// In en, this message translates to:
  /// **'Looking for peers…'**
  String get peersEmpty;

  /// No description provided for @peersHopsOne.
  ///
  /// In en, this message translates to:
  /// **'{n} hop away'**
  String peersHopsOne(int n);

  /// No description provided for @peersHopsOther.
  ///
  /// In en, this message translates to:
  /// **'{n} hops away'**
  String peersHopsOther(int n);

  /// No description provided for @blePermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth permission needed'**
  String get blePermissionTitle;

  /// No description provided for @blePermissionHint.
  ///
  /// In en, this message translates to:
  /// **'Cubechat needs Bluetooth to find peers and send messages — no internet required.'**
  String get blePermissionHint;

  /// No description provided for @blePermissionGrant.
  ///
  /// In en, this message translates to:
  /// **'Grant permission'**
  String get blePermissionGrant;

  /// No description provided for @blePermissionOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get blePermissionOpenSettings;

  /// No description provided for @blePermissionDeniedHint.
  ///
  /// In en, this message translates to:
  /// **'Permission was denied. Open settings to allow Bluetooth access.'**
  String get blePermissionDeniedHint;

  /// No description provided for @bleAdapterOffTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off'**
  String get bleAdapterOffTitle;

  /// No description provided for @bleAdapterOffHint.
  ///
  /// In en, this message translates to:
  /// **'Turn Bluetooth on to see peers nearby.'**
  String get bleAdapterOffHint;

  /// No description provided for @bleUnsupportedTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth LE not available'**
  String get bleUnsupportedTitle;

  /// No description provided for @bleUnsupportedHint.
  ///
  /// In en, this message translates to:
  /// **'This device or platform doesn\'t expose Bluetooth Low Energy. Try it on a phone.'**
  String get bleUnsupportedHint;

  /// No description provided for @bleScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning…'**
  String get bleScanning;

  /// No description provided for @bleRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get bleRetry;

  /// No description provided for @bleConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t connect. The peer may be out of range, or its Bluetooth address changed.'**
  String get bleConnectFailed;

  /// No description provided for @bleSignal.
  ///
  /// In en, this message translates to:
  /// **'Signal'**
  String get bleSignal;

  /// No description provided for @bleConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get bleConnect;

  /// No description provided for @bleConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get bleConnected;

  /// No description provided for @bleVerified.
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get bleVerified;

  /// No description provided for @bleUnknownPeer.
  ///
  /// In en, this message translates to:
  /// **'Unidentified peer'**
  String get bleUnknownPeer;

  /// No description provided for @bleBroadcasting.
  ///
  /// In en, this message translates to:
  /// **'Broadcasting'**
  String get bleBroadcasting;

  /// No description provided for @bleConnectedCount.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =0{No centrals} =1{1 central connected} other{{n} centrals connected}}'**
  String bleConnectedCount(int n);

  /// No description provided for @verifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify peer'**
  String get verifyTitle;

  /// No description provided for @verifyIntro.
  ///
  /// In en, this message translates to:
  /// **'Compare these two fingerprints with your peer in person or over a voice call. If they match on both sides, you have confirmed the Noise handshake was not tampered with.'**
  String get verifyIntro;

  /// No description provided for @verifyMine.
  ///
  /// In en, this message translates to:
  /// **'YOUR FINGERPRINT'**
  String get verifyMine;

  /// No description provided for @verifyTheirs.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s FINGERPRINT'**
  String verifyTheirs(String name);

  /// No description provided for @verifyMarkAsVerified.
  ///
  /// In en, this message translates to:
  /// **'Mark as verified'**
  String get verifyMarkAsVerified;

  /// No description provided for @verifyAlreadyDone.
  ///
  /// In en, this message translates to:
  /// **'This peer is verified.'**
  String get verifyAlreadyDone;

  /// No description provided for @verifyRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get verifyRevoke;

  /// No description provided for @verifyDoneSnack.
  ///
  /// In en, this message translates to:
  /// **'{name} marked as verified'**
  String verifyDoneSnack(String name);

  /// No description provided for @chatInputHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get chatInputHint;

  /// No description provided for @chatSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSend;

  /// No description provided for @chatToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get chatToday;

  /// No description provided for @chatYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get chatYesterday;

  /// No description provided for @chatDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get chatDelivered;

  /// No description provided for @chatRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get chatRead;

  /// No description provided for @chatSending.
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get chatSending;

  /// No description provided for @chatEncryptedNotice.
  ///
  /// In en, this message translates to:
  /// **'Messages are end-to-end encrypted with the Noise Protocol.'**
  String get chatEncryptedNotice;

  /// No description provided for @chatSessionHandshaking.
  ///
  /// In en, this message translates to:
  /// **'Establishing secure channel…'**
  String get chatSessionHandshaking;

  /// No description provided for @chatSessionEstablished.
  ///
  /// In en, this message translates to:
  /// **'Secured · Noise XX'**
  String get chatSessionEstablished;

  /// No description provided for @chatSessionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get chatSessionFailed;

  /// No description provided for @presenceOnline.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get presenceOnline;

  /// No description provided for @presenceOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get presenceOffline;

  /// No description provided for @chatSessionFingerprintPending.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint will appear once the handshake completes.'**
  String get chatSessionFingerprintPending;

  /// No description provided for @chatEmptyEstablished.
  ///
  /// In en, this message translates to:
  /// **'The secure channel is up. Send a message to start the conversation.'**
  String get chatEmptyEstablished;

  /// No description provided for @chatEmptyHandshaking.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the other side to finish the handshake…'**
  String get chatEmptyHandshaking;

  /// No description provided for @profileTitle.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profileTitle;

  /// No description provided for @profileNickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get profileNickname;

  /// No description provided for @profileNicknameEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Set your nickname'**
  String get profileNicknameEditTitle;

  /// No description provided for @profileNicknameHint.
  ///
  /// In en, this message translates to:
  /// **'How others see you on the mesh'**
  String get profileNicknameHint;

  /// No description provided for @profileNicknameSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get profileNicknameSave;

  /// No description provided for @profileFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Public key fingerprint'**
  String get profileFingerprint;

  /// No description provided for @profileLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get profileLanguage;

  /// No description provided for @profileLanguageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get profileLanguageEn;

  /// No description provided for @profileLanguageUk.
  ///
  /// In en, this message translates to:
  /// **'Ukrainian'**
  String get profileLanguageUk;

  /// No description provided for @profileTransport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get profileTransport;

  /// No description provided for @profileTransportMesh.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth mesh'**
  String get profileTransportMesh;

  /// No description provided for @profileBackground.
  ///
  /// In en, this message translates to:
  /// **'Stay reachable in background'**
  String get profileBackground;

  /// No description provided for @profileBackgroundSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keep receiving messages while the app is closed'**
  String get profileBackgroundSubtitle;

  /// No description provided for @profileBatteryExempt.
  ///
  /// In en, this message translates to:
  /// **'Disable battery optimisation'**
  String get profileBatteryExempt;

  /// No description provided for @profileAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get profileAbout;

  /// No description provided for @profileVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {v}'**
  String profileVersion(String v);

  /// No description provided for @profileEmergencyWipe.
  ///
  /// In en, this message translates to:
  /// **'Emergency wipe'**
  String get profileEmergencyWipe;

  /// No description provided for @profileEmergencyWipeHint.
  ///
  /// In en, this message translates to:
  /// **'Triple-tap to erase all keys, peers, and messages.'**
  String get profileEmergencyWipeHint;

  /// No description provided for @profileEmergencyWipeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Erase everything?'**
  String get profileEmergencyWipeConfirm;

  /// No description provided for @profileEmergencyWipeConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'This will remove your identity, peer list, and conversation history. Cannot be undone.'**
  String get profileEmergencyWipeConfirmHint;

  /// No description provided for @profileEmergencyWipeAction.
  ///
  /// In en, this message translates to:
  /// **'Erase'**
  String get profileEmergencyWipeAction;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @channelsNewTitle.
  ///
  /// In en, this message translates to:
  /// **'New channel'**
  String get channelsNewTitle;

  /// No description provided for @channelsNewTooltip.
  ///
  /// In en, this message translates to:
  /// **'New channel'**
  String get channelsNewTooltip;

  /// No description provided for @channelNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Channel name'**
  String get channelNameLabel;

  /// No description provided for @channelPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password (optional)'**
  String get channelPasswordLabel;

  /// No description provided for @channelJoinAction.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get channelJoinAction;

  /// No description provided for @channelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Group channel · shared key'**
  String get channelSubtitle;

  /// No description provided for @chatsStatusChannel.
  ///
  /// In en, this message translates to:
  /// **'channel'**
  String get chatsStatusChannel;

  /// No description provided for @channelInviteTitle.
  ///
  /// In en, this message translates to:
  /// **'Add people'**
  String get channelInviteTitle;

  /// No description provided for @channelInviteAction.
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get channelInviteAction;

  /// No description provided for @channelInviteEmpty.
  ///
  /// In en, this message translates to:
  /// **'No known peers yet. Meet someone on the Nearby tab first.'**
  String get channelInviteEmpty;

  /// No description provided for @channelInviteSent.
  ///
  /// In en, this message translates to:
  /// **'Invitations sent'**
  String get channelInviteSent;

  /// No description provided for @channelInviteNoneSent.
  ///
  /// In en, this message translates to:
  /// **'Nobody could be reached right now'**
  String get channelInviteNoneSent;

  /// No description provided for @channelNameTooLong.
  ///
  /// In en, this message translates to:
  /// **'That channel name is too long'**
  String get channelNameTooLong;

  /// No description provided for @chatsActionFavorite.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get chatsActionFavorite;

  /// No description provided for @chatsActionUnfavorite.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites'**
  String get chatsActionUnfavorite;

  /// No description provided for @chatsActionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get chatsActionDelete;

  /// No description provided for @chatsDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this chat?'**
  String get chatsDeleteTitle;

  /// No description provided for @chatsDeletePeerHint.
  ///
  /// In en, this message translates to:
  /// **'Removes the conversation and forgets this peer. They can find you again over the mesh.'**
  String get chatsDeletePeerHint;

  /// No description provided for @chatsDeleteChannelHint.
  ///
  /// In en, this message translates to:
  /// **'Leaves the channel and removes its history. You will need the key again to rejoin.'**
  String get chatsDeleteChannelHint;

  /// No description provided for @chatsDeleteForThemToo.
  ///
  /// In en, this message translates to:
  /// **'Also delete for them'**
  String get chatsDeleteForThemToo;

  /// No description provided for @chatsDeleteForThemHint.
  ///
  /// In en, this message translates to:
  /// **'Withdraws the messages you sent from their device too. Their own messages stay.'**
  String get chatsDeleteForThemHint;

  /// No description provided for @chatEditAction.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get chatEditAction;

  /// No description provided for @chatEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get chatEditTitle;

  /// No description provided for @chatEditSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get chatEditSave;

  /// No description provided for @chatEdited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get chatEdited;

  /// No description provided for @chatDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatDeleteAction;

  /// No description provided for @chatDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete message?'**
  String get chatDeleteTitle;

  /// No description provided for @chatDeleteForMe.
  ///
  /// In en, this message translates to:
  /// **'Delete for me'**
  String get chatDeleteForMe;

  /// No description provided for @chatDeleteForEveryone.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get chatDeleteForEveryone;

  /// No description provided for @chatReplyAction.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get chatReplyAction;

  /// No description provided for @chatReplyingTo.
  ///
  /// In en, this message translates to:
  /// **'Replying to {name}'**
  String chatReplyingTo(String name);

  /// No description provided for @chatReplyYou.
  ///
  /// In en, this message translates to:
  /// **'yourself'**
  String get chatReplyYou;

  /// No description provided for @chatCopyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get chatCopyAction;

  /// No description provided for @chatCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get chatCopied;

  /// No description provided for @chatForwardAction.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get chatForwardAction;

  /// No description provided for @chatForwardTitle.
  ///
  /// In en, this message translates to:
  /// **'Forward to'**
  String get chatForwardTitle;

  /// No description provided for @chatForwardEmpty.
  ///
  /// In en, this message translates to:
  /// **'No other chats yet'**
  String get chatForwardEmpty;

  /// No description provided for @chatForwardSent.
  ///
  /// In en, this message translates to:
  /// **'Forwarded to {name}'**
  String chatForwardSent(String name);

  /// No description provided for @chatSentAt.
  ///
  /// In en, this message translates to:
  /// **'Sent {time}'**
  String chatSentAt(String time);

  /// No description provided for @chatReadAt.
  ///
  /// In en, this message translates to:
  /// **'Read {time}'**
  String chatReadAt(String time);

  /// No description provided for @chatPinAction.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get chatPinAction;

  /// No description provided for @chatUnpinAction.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get chatUnpinAction;

  /// No description provided for @chatUnpinConfirm.
  ///
  /// In en, this message translates to:
  /// **'Unpin this message?'**
  String get chatUnpinConfirm;

  /// No description provided for @chatUnpinConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'It stops being pinned for everyone in this chat.'**
  String get chatUnpinConfirmHint;

  /// No description provided for @chatPinnedTitle.
  ///
  /// In en, this message translates to:
  /// **'Pinned message'**
  String get chatPinnedTitle;

  /// No description provided for @chatPinnedGone.
  ///
  /// In en, this message translates to:
  /// **'That message is no longer in this chat'**
  String get chatPinnedGone;

  /// No description provided for @peerBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get peerBlock;

  /// No description provided for @peerUnblock.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get peerUnblock;

  /// No description provided for @peerMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get peerMute;

  /// No description provided for @peerUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get peerUnmute;

  /// No description provided for @peerBlockedNote.
  ///
  /// In en, this message translates to:
  /// **'Blocked — their messages are dropped.'**
  String get peerBlockedNote;

  /// No description provided for @relaysTitle.
  ///
  /// In en, this message translates to:
  /// **'Internet fallback'**
  String get relaysTitle;

  /// No description provided for @relaysCardTitle.
  ///
  /// In en, this message translates to:
  /// **'Reach peers over the internet'**
  String get relaysCardTitle;

  /// No description provided for @relaysCardSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When Bluetooth can\'t deliver, send via Nostr relays'**
  String get relaysCardSubtitle;

  /// No description provided for @relaysExplainer.
  ///
  /// In en, this message translates to:
  /// **'Messages stay end-to-end encrypted — a relay only carries the same sealed frame Bluetooth would. It does learn which two keys are talking, and when. Off by default.'**
  String get relaysExplainer;

  /// No description provided for @relaysMyAddress.
  ///
  /// In en, this message translates to:
  /// **'Your relay address'**
  String get relaysMyAddress;

  /// No description provided for @relaysCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get relaysCopied;

  /// No description provided for @relaysListLabel.
  ///
  /// In en, this message translates to:
  /// **'Relays'**
  String get relaysListLabel;

  /// No description provided for @relaysAdd.
  ///
  /// In en, this message translates to:
  /// **'Add relay'**
  String get relaysAdd;

  /// No description provided for @relaysAddHint.
  ///
  /// In en, this message translates to:
  /// **'wss://relay.example.com'**
  String get relaysAddHint;

  /// No description provided for @relaysInvalidUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter a wss:// or ws:// address'**
  String get relaysInvalidUrl;

  /// No description provided for @relaysRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get relaysRemove;

  /// No description provided for @relaysStateConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get relaysStateConnected;

  /// No description provided for @relaysStateConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get relaysStateConnecting;

  /// No description provided for @relaysStateFailed.
  ///
  /// In en, this message translates to:
  /// **'Unreachable'**
  String get relaysStateFailed;

  /// No description provided for @relaysStateIdle.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get relaysStateIdle;

  /// No description provided for @relaysEmpty.
  ///
  /// In en, this message translates to:
  /// **'No relays configured — the fallback stays off.'**
  String get relaysEmpty;

  /// No description provided for @contactTitle.
  ///
  /// In en, this message translates to:
  /// **'Contact card'**
  String get contactTitle;

  /// No description provided for @contactMineLabel.
  ///
  /// In en, this message translates to:
  /// **'Your card'**
  String get contactMineLabel;

  /// No description provided for @contactMineExplainer.
  ///
  /// In en, this message translates to:
  /// **'Send this to someone who is out of Bluetooth range. It carries your keys and your relay address — enough for them to start an encrypted chat with you over the internet.'**
  String get contactMineExplainer;

  /// No description provided for @contactCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get contactCopy;

  /// No description provided for @contactShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get contactShare;

  /// No description provided for @contactCopied.
  ///
  /// In en, this message translates to:
  /// **'Card copied'**
  String get contactCopied;

  /// No description provided for @contactShareSubject.
  ///
  /// In en, this message translates to:
  /// **'My cubechat contact card'**
  String get contactShareSubject;

  /// No description provided for @contactAddLabel.
  ///
  /// In en, this message translates to:
  /// **'Add someone'**
  String get contactAddLabel;

  /// No description provided for @contactAddHint.
  ///
  /// In en, this message translates to:
  /// **'Paste a contact card'**
  String get contactAddHint;

  /// No description provided for @contactAddAction.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get contactAddAction;

  /// No description provided for @contactPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get contactPaste;

  /// No description provided for @contactAdded.
  ///
  /// In en, this message translates to:
  /// **'Added {name}'**
  String contactAdded(String name);

  /// No description provided for @contactInvalid.
  ///
  /// In en, this message translates to:
  /// **'That isn\'t a valid contact card'**
  String get contactInvalid;

  /// No description provided for @contactOwnCard.
  ///
  /// In en, this message translates to:
  /// **'That\'s your own card'**
  String get contactOwnCard;

  /// No description provided for @contactUnverified.
  ///
  /// In en, this message translates to:
  /// **'A contact added this way starts unverified. Anyone can mint a card and put any name on it, so compare fingerprints in person or over a call before you trust the identity.'**
  String get contactUnverified;

  /// No description provided for @contactRelayOff.
  ///
  /// In en, this message translates to:
  /// **'Internet fallback is off, so a card can\'t reach anyone yet.'**
  String get contactRelayOff;

  /// No description provided for @contactRelayEnable.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get contactRelayEnable;

  /// No description provided for @profileContactCard.
  ///
  /// In en, this message translates to:
  /// **'Contact card'**
  String get profileContactCard;

  /// No description provided for @profileContactCardSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Chat with someone out of Bluetooth range'**
  String get profileContactCardSubtitle;

  /// No description provided for @chatsAddContactTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add a contact by card'**
  String get chatsAddContactTooltip;

  /// No description provided for @chatsMenuTooltip.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get chatsMenuTooltip;

  /// No description provided for @chatsMenuAddContact.
  ///
  /// In en, this message translates to:
  /// **'Add contact'**
  String get chatsMenuAddContact;

  /// No description provided for @chatsMenuNewChannel.
  ///
  /// In en, this message translates to:
  /// **'New channel'**
  String get chatsMenuNewChannel;

  /// No description provided for @profileDiscoverable.
  ///
  /// In en, this message translates to:
  /// **'Discoverable nearby'**
  String get profileDiscoverable;

  /// No description provided for @profileDiscoverableOnHint.
  ///
  /// In en, this message translates to:
  /// **'Anyone in range can find you'**
  String get profileDiscoverableOnHint;

  /// No description provided for @profileDiscoverableOffHint.
  ///
  /// In en, this message translates to:
  /// **'Only your contacts can reach you'**
  String get profileDiscoverableOffHint;

  /// No description provided for @profileDiscoverableExplainer.
  ///
  /// In en, this message translates to:
  /// **'On, your announcement is broadcast in the clear so strangers can meet you by walking up — and anyone listening records your key and name. Off, the same bundle goes only to contacts you already have, sealed, and your routing ids stay unlinkable. New people then need a contact card.'**
  String get profileDiscoverableExplainer;

  /// No description provided for @voiceHoldHint.
  ///
  /// In en, this message translates to:
  /// **'Hold to record a voice message'**
  String get voiceHoldHint;

  /// No description provided for @voiceTrimPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get voiceTrimPlay;

  /// No description provided for @voiceTrimPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get voiceTrimPause;

  /// No description provided for @voiceTrimDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard recording'**
  String get voiceTrimDiscard;

  /// No description provided for @voiceTrimSelection.
  ///
  /// In en, this message translates to:
  /// **'Sending {duration}'**
  String voiceTrimSelection(String duration);

  /// No description provided for @profilePrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get profilePrivacy;

  /// No description provided for @profileLastSeen.
  ///
  /// In en, this message translates to:
  /// **'Share last seen'**
  String get profileLastSeen;

  /// No description provided for @profileLastSeenOnHint.
  ///
  /// In en, this message translates to:
  /// **'Contacts can see when you\'re in the app'**
  String get profileLastSeenOnHint;

  /// No description provided for @profileLastSeenOffHint.
  ///
  /// In en, this message translates to:
  /// **'Nobody sees yours — and you see nobody\'s'**
  String get profileLastSeenOffHint;

  /// No description provided for @profileReadReceipts.
  ///
  /// In en, this message translates to:
  /// **'Share read receipts'**
  String get profileReadReceipts;

  /// No description provided for @profileReadReceiptsOnHint.
  ///
  /// In en, this message translates to:
  /// **'Senders see when you\'ve read them'**
  String get profileReadReceiptsOnHint;

  /// No description provided for @profileReadReceiptsOffHint.
  ///
  /// In en, this message translates to:
  /// **'They don\'t — and neither do you'**
  String get profileReadReceiptsOffHint;

  /// No description provided for @profilePrivacyExplainer.
  ///
  /// In en, this message translates to:
  /// **'Both switches cut both ways: hide your own status and you stop seeing everyone else\'s. Anything else would be a one-way mirror. Message delivery is untouched.'**
  String get profilePrivacyExplainer;

  /// No description provided for @avatarSet.
  ///
  /// In en, this message translates to:
  /// **'Choose a photo'**
  String get avatarSet;

  /// No description provided for @avatarChange.
  ///
  /// In en, this message translates to:
  /// **'Change photo'**
  String get avatarChange;

  /// No description provided for @avatarRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove photo'**
  String get avatarRemove;

  /// No description provided for @avatarRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'The avatar will be deleted from this device. The generated gradient comes back in its place.'**
  String get avatarRemoveConfirm;

  /// No description provided for @avatarFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read that image'**
  String get avatarFailed;

  /// No description provided for @fileOpenHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to open'**
  String get fileOpenHint;

  /// No description provided for @fileMissing.
  ///
  /// In en, this message translates to:
  /// **'That file is no longer available'**
  String get fileMissing;

  /// No description provided for @fileNoHandlerTitle.
  ///
  /// In en, this message translates to:
  /// **'No app can open this'**
  String get fileNoHandlerTitle;

  /// No description provided for @fileNoHandlerHint.
  ///
  /// In en, this message translates to:
  /// **'Nothing installed handles this file type. You can send it to another app instead.'**
  String get fileNoHandlerHint;

  /// No description provided for @fileRequestedAgain.
  ///
  /// In en, this message translates to:
  /// **'Asked the sender for it again'**
  String get fileRequestedAgain;

  /// No description provided for @fileOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open this file'**
  String get fileOpenFailed;

  /// No description provided for @fileShareAction.
  ///
  /// In en, this message translates to:
  /// **'Send to app'**
  String get fileShareAction;

  /// No description provided for @fileTooLargeMesh.
  ///
  /// In en, this message translates to:
  /// **'File is too large — {limit} MB is the limit over the mesh'**
  String fileTooLargeMesh(int limit);

  /// No description provided for @fileTooLargeRelay.
  ///
  /// In en, this message translates to:
  /// **'Over the internet the limit is {limit} MB. Get closer to the recipient to send a bigger file.'**
  String fileTooLargeRelay(int limit);

  /// No description provided for @mediaSendOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get mediaSendOriginal;

  /// No description provided for @attachFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get attachFile;

  /// No description provided for @attachGallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get attachGallery;

  /// No description provided for @attachCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get attachCamera;

  /// No description provided for @profileEditName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get profileEditName;

  /// No description provided for @profileMyCard.
  ///
  /// In en, this message translates to:
  /// **'Card'**
  String get profileMyCard;

  /// No description provided for @mediaCaptionHint.
  ///
  /// In en, this message translates to:
  /// **'Add a caption…'**
  String get mediaCaptionHint;

  /// No description provided for @contactProfileAutoDelete.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete chat'**
  String get contactProfileAutoDelete;

  /// No description provided for @contactProfileAutoDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete messages'**
  String get contactProfileAutoDeleteTitle;

  /// No description provided for @contactProfileAutoDeleteOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get contactProfileAutoDeleteOff;

  /// No description provided for @contactProfileAutoDeleteOneDay.
  ///
  /// In en, this message translates to:
  /// **'After 1 day'**
  String get contactProfileAutoDeleteOneDay;

  /// No description provided for @contactProfileAutoDeleteSevenDays.
  ///
  /// In en, this message translates to:
  /// **'After 7 days'**
  String get contactProfileAutoDeleteSevenDays;

  /// No description provided for @contactProfileAutoDeleteThirtyDays.
  ///
  /// In en, this message translates to:
  /// **'After 30 days'**
  String get contactProfileAutoDeleteThirtyDays;

  /// No description provided for @contactProfileAutoDeleteUpdated.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete: {period}'**
  String contactProfileAutoDeleteUpdated(String period);

  /// No description provided for @contactProfileShare.
  ///
  /// In en, this message translates to:
  /// **'Share contact'**
  String get contactProfileShare;

  /// No description provided for @contactProfileShareTitle.
  ///
  /// In en, this message translates to:
  /// **'Send contact to'**
  String get contactProfileShareTitle;

  /// No description provided for @contactProfileShareEmpty.
  ///
  /// In en, this message translates to:
  /// **'No other chats yet'**
  String get contactProfileShareEmpty;

  /// No description provided for @contactProfileShareSent.
  ///
  /// In en, this message translates to:
  /// **'Sent to {name}'**
  String contactProfileShareSent(String name);

  /// No description provided for @contactProfileRestrictCopying.
  ///
  /// In en, this message translates to:
  /// **'Disable copying'**
  String get contactProfileRestrictCopying;

  /// No description provided for @contactProfileAllowCopying.
  ///
  /// In en, this message translates to:
  /// **'Allow copying'**
  String get contactProfileAllowCopying;

  /// No description provided for @contactProfileCopyingRestricted.
  ///
  /// In en, this message translates to:
  /// **'Copying and forwarding are disabled'**
  String get contactProfileCopyingRestricted;

  /// No description provided for @contactProfileCopyingAllowed.
  ///
  /// In en, this message translates to:
  /// **'Copying and forwarding are allowed'**
  String get contactProfileCopyingAllowed;

  /// No description provided for @contactProfileDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete from contacts'**
  String get contactProfileDelete;

  /// No description provided for @contactProfileDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove contact?'**
  String get contactProfileDeleteTitle;

  /// No description provided for @contactProfileDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'{name} will disappear from Contacts. Chat history stays on this device.'**
  String contactProfileDeleteMessage(String name);

  /// No description provided for @contactProfileMedia.
  ///
  /// In en, this message translates to:
  /// **'Media'**
  String get contactProfileMedia;

  /// No description provided for @contactProfileVoiceMessages.
  ///
  /// In en, this message translates to:
  /// **'Voice messages'**
  String get contactProfileVoiceMessages;

  /// No description provided for @contactProfileNoMedia.
  ///
  /// In en, this message translates to:
  /// **'No media yet'**
  String get contactProfileNoMedia;

  /// No description provided for @contactProfileNoVoiceMessages.
  ///
  /// In en, this message translates to:
  /// **'No voice messages yet'**
  String get contactProfileNoVoiceMessages;

  /// No description provided for @contactProfileOpen.
  ///
  /// In en, this message translates to:
  /// **'Open profile'**
  String get contactProfileOpen;

  /// No description provided for @autoDeleteDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} day} other{{count} days}}'**
  String autoDeleteDays(int count);

  /// No description provided for @autoDeleteHours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} hour} other{{count} hours}}'**
  String autoDeleteHours(int count);

  /// No description provided for @autoDeleteMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} minute} other{{count} minutes}}'**
  String autoDeleteMinutes(int count);

  /// No description provided for @autoDeleteSeconds.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} second} other{{count} seconds}}'**
  String autoDeleteSeconds(int count);

  /// No description provided for @autoDeleteCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get autoDeleteCustom;

  /// No description provided for @autoDeleteCustomHint.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get autoDeleteCustomHint;

  /// No description provided for @autoDeleteUnitMinutes.
  ///
  /// In en, this message translates to:
  /// **'min'**
  String get autoDeleteUnitMinutes;

  /// No description provided for @autoDeleteUnitHours.
  ///
  /// In en, this message translates to:
  /// **'hours'**
  String get autoDeleteUnitHours;

  /// No description provided for @autoDeleteUnitDays.
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get autoDeleteUnitDays;

  /// No description provided for @contactProfileAutoDeleteSet.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get contactProfileAutoDeleteSet;

  /// No description provided for @contactProfileFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get contactProfileFiles;

  /// No description provided for @contactProfileNoFiles.
  ///
  /// In en, this message translates to:
  /// **'No files yet'**
  String get contactProfileNoFiles;

  /// No description provided for @contactProfileLinks.
  ///
  /// In en, this message translates to:
  /// **'Links'**
  String get contactProfileLinks;

  /// No description provided for @contactProfileNoLinks.
  ///
  /// In en, this message translates to:
  /// **'No links yet'**
  String get contactProfileNoLinks;

  /// No description provided for @contactProfilePolls.
  ///
  /// In en, this message translates to:
  /// **'Polls'**
  String get contactProfilePolls;

  /// No description provided for @contactProfileNoPolls.
  ///
  /// In en, this message translates to:
  /// **'No polls yet'**
  String get contactProfileNoPolls;

  /// No description provided for @presenceHidden.
  ///
  /// In en, this message translates to:
  /// **'status hidden'**
  String get presenceHidden;

  /// No description provided for @chatReadByCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Read by {count}} other{Read by {count}}}'**
  String chatReadByCount(int count);

  /// No description provided for @chatsSearchFrequent.
  ///
  /// In en, this message translates to:
  /// **'People you talk to'**
  String get chatsSearchFrequent;

  /// No description provided for @chatsSearchRecent.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get chatsSearchRecent;

  /// No description provided for @chatsSearchClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get chatsSearchClear;

  /// No description provided for @chatsSearchStartHint.
  ///
  /// In en, this message translates to:
  /// **'Search your chats and channels by name.'**
  String get chatsSearchStartHint;

  /// No description provided for @chatsSearchEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing matches that'**
  String get chatsSearchEmpty;

  /// No description provided for @contactProfileViewInChat.
  ///
  /// In en, this message translates to:
  /// **'View in chat'**
  String get contactProfileViewInChat;

  /// No description provided for @chatDraft.
  ///
  /// In en, this message translates to:
  /// **'Draft'**
  String get chatDraft;

  /// No description provided for @chatSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get chatSearchTitle;

  /// No description provided for @chatSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search messages'**
  String get chatSearchHint;

  /// No description provided for @chatSearchNoResults.
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get chatSearchNoResults;

  /// No description provided for @chatSearchPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous result'**
  String get chatSearchPrevious;

  /// No description provided for @chatSearchNext.
  ///
  /// In en, this message translates to:
  /// **'Next result'**
  String get chatSearchNext;

  /// No description provided for @chatMessageCount.
  ///
  /// In en, this message translates to:
  /// **'{count} messages'**
  String chatMessageCount(int count);

  /// No description provided for @chatRouteBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth'**
  String get chatRouteBluetooth;

  /// No description provided for @chatRouteMesh.
  ///
  /// In en, this message translates to:
  /// **'Mesh'**
  String get chatRouteMesh;

  /// No description provided for @chatRouteInternet.
  ///
  /// In en, this message translates to:
  /// **'Internet'**
  String get chatRouteInternet;

  /// No description provided for @chatRouteQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get chatRouteQueued;

  /// No description provided for @chatAttachmentUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No connection is available. Connect over Bluetooth or the internet and try again.'**
  String get chatAttachmentUnavailable;

  /// No description provided for @fileTransfersTitle.
  ///
  /// In en, this message translates to:
  /// **'File transfers'**
  String get fileTransfersTitle;

  /// No description provided for @fileTransfersClear.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get fileTransfersClear;

  /// No description provided for @fileTransfersEmpty.
  ///
  /// In en, this message translates to:
  /// **'No file transfers yet'**
  String get fileTransfersEmpty;

  /// No description provided for @fileTransfersActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get fileTransfersActive;

  /// No description provided for @fileTransfersHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get fileTransfersHistory;

  /// No description provided for @fileTransferPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get fileTransferPause;

  /// No description provided for @fileTransferResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get fileTransferResume;

  /// No description provided for @fileTransferRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get fileTransferRetry;

  /// No description provided for @fileTransferQueued.
  ///
  /// In en, this message translates to:
  /// **'Waiting for connection'**
  String get fileTransferQueued;

  /// No description provided for @fileTransferRunning.
  ///
  /// In en, this message translates to:
  /// **'Transferring'**
  String get fileTransferRunning;

  /// No description provided for @fileTransferPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get fileTransferPaused;

  /// No description provided for @fileTransferCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get fileTransferCompleted;

  /// No description provided for @fileTransferFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get fileTransferFailed;

  /// No description provided for @fileTransferCanceled.
  ///
  /// In en, this message translates to:
  /// **'Canceled'**
  String get fileTransferCanceled;

  /// No description provided for @profileFileTransfers.
  ///
  /// In en, this message translates to:
  /// **'File transfers'**
  String get profileFileTransfers;

  /// No description provided for @profileFileTransfersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Progress, queue and transfer history'**
  String get profileFileTransfersSubtitle;

  /// No description provided for @qrScanAction.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get qrScanAction;

  /// No description provided for @qrScanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get qrScanTitle;

  /// No description provided for @qrScanHint.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at a Cubechat contact or channel QR code.'**
  String get qrScanHint;

  /// No description provided for @qrFlash.
  ///
  /// In en, this message translates to:
  /// **'Flashlight'**
  String get qrFlash;

  /// No description provided for @qrCameraError.
  ///
  /// In en, this message translates to:
  /// **'Camera is unavailable. Check camera permission and try again.'**
  String get qrCameraError;

  /// No description provided for @qrInvalid.
  ///
  /// In en, this message translates to:
  /// **'This is not a valid Cubechat QR code.'**
  String get qrInvalid;

  /// No description provided for @qrChannelAdded.
  ///
  /// In en, this message translates to:
  /// **'{name} added'**
  String qrChannelAdded(String name);

  /// No description provided for @qrShow.
  ///
  /// In en, this message translates to:
  /// **'Show QR code'**
  String get qrShow;

  /// No description provided for @qrChannelTitle.
  ///
  /// In en, this message translates to:
  /// **'Join {name}'**
  String qrChannelTitle(String name);

  /// No description provided for @profileBackup.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup'**
  String get profileBackup;

  /// No description provided for @profileBackupSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Move keys, contacts and history safely'**
  String get profileBackupSubtitle;

  /// No description provided for @backupTitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup'**
  String get backupTitle;

  /// No description provided for @backupExplainer.
  ///
  /// In en, this message translates to:
  /// **'The backup contains your private identity keys, contacts, channels, settings and message history. It is encrypted on this phone with the password you choose; Cubechat cannot recover a forgotten password.'**
  String get backupExplainer;

  /// No description provided for @backupCreate.
  ///
  /// In en, this message translates to:
  /// **'Create backup'**
  String get backupCreate;

  /// No description provided for @backupCreateSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypt everything and save a .cchatbackup file'**
  String get backupCreateSubtitle;

  /// No description provided for @backupRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore backup'**
  String get backupRestore;

  /// No description provided for @backupRestoreSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Replace this phone’s Cubechat profile from a backup file'**
  String get backupRestoreSubtitle;

  /// No description provided for @backupPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Backup password'**
  String get backupPasswordTitle;

  /// No description provided for @backupPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'At least 8 characters'**
  String get backupPasswordHint;

  /// No description provided for @backupConfirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Repeat password'**
  String get backupConfirmPassword;

  /// No description provided for @backupPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get backupPasswordMismatch;

  /// No description provided for @backupPasswordShort.
  ///
  /// In en, this message translates to:
  /// **'Use at least 8 characters'**
  String get backupPasswordShort;

  /// No description provided for @backupSaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Save Cubechat backup'**
  String get backupSaveTitle;

  /// No description provided for @backupSaved.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup saved'**
  String get backupSaved;

  /// No description provided for @backupFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not complete the backup operation'**
  String get backupFailed;

  /// No description provided for @backupRestoreConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace this profile?'**
  String get backupRestoreConfirmTitle;

  /// No description provided for @backupRestoreConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Current keys, contacts, channels, settings and history on this phone will be replaced by the selected backup.'**
  String get backupRestoreConfirmMessage;

  /// No description provided for @backupRestoreConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupRestoreConfirmAction;

  /// No description provided for @backupRestored.
  ///
  /// In en, this message translates to:
  /// **'Backup restored'**
  String get backupRestored;

  /// No description provided for @backupInvalid.
  ///
  /// In en, this message translates to:
  /// **'Wrong password, damaged file, or unsupported backup'**
  String get backupInvalid;

  /// No description provided for @channelInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Channel details'**
  String get channelInfoTitle;

  /// No description provided for @channelParticipantsTitle.
  ///
  /// In en, this message translates to:
  /// **'Participants'**
  String get channelParticipantsTitle;

  /// No description provided for @channelAdministratorsTitle.
  ///
  /// In en, this message translates to:
  /// **'Administrators'**
  String get channelAdministratorsTitle;

  /// No description provided for @channelMakeAdmin.
  ///
  /// In en, this message translates to:
  /// **'Make administrator'**
  String get channelMakeAdmin;

  /// No description provided for @channelRemoveAdmin.
  ///
  /// In en, this message translates to:
  /// **'Remove administrator'**
  String get channelRemoveAdmin;

  /// No description provided for @channelNoParticipants.
  ///
  /// In en, this message translates to:
  /// **'Participants will appear after signed activity'**
  String get channelNoParticipants;

  /// No description provided for @channelSharedContent.
  ///
  /// In en, this message translates to:
  /// **'Media, files and polls'**
  String get channelSharedContent;

  /// No description provided for @channelDescriptionTitle.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get channelDescriptionTitle;

  /// No description provided for @channelDescriptionEmpty.
  ///
  /// In en, this message translates to:
  /// **'No description yet'**
  String get channelDescriptionEmpty;

  /// No description provided for @channelDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'What this channel is for'**
  String get channelDescriptionHint;

  /// No description provided for @channelDescriptionAdminOnly.
  ///
  /// In en, this message translates to:
  /// **'Only an administrator can change the description'**
  String get channelDescriptionAdminOnly;

  /// No description provided for @channelDescriptionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get channelDescriptionSave;

  /// No description provided for @chatTyping.
  ///
  /// In en, this message translates to:
  /// **'typing…'**
  String get chatTyping;

  /// No description provided for @onboardingMeshTitle.
  ///
  /// In en, this message translates to:
  /// **'Works without internet'**
  String get onboardingMeshTitle;

  /// No description provided for @onboardingMeshBody.
  ///
  /// In en, this message translates to:
  /// **'Messages travel over Bluetooth, phone to phone. No signal, no Wi-Fi, no accounts — just the people around you.'**
  String get onboardingMeshBody;

  /// No description provided for @onboardingRelayTitle.
  ///
  /// In en, this message translates to:
  /// **'And with it, when there is some'**
  String get onboardingRelayTitle;

  /// No description provided for @onboardingRelayBody.
  ///
  /// In en, this message translates to:
  /// **'Out of Bluetooth range, messages take the internet instead and arrive the same way. You never pick which.'**
  String get onboardingRelayBody;

  /// No description provided for @onboardingPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nobody in the middle can read it'**
  String get onboardingPrivacyTitle;

  /// No description provided for @onboardingPrivacyBody.
  ///
  /// In en, this message translates to:
  /// **'Everything is end-to-end encrypted, and your identity is a key on this phone — not a phone number, not an email, not an account anyone can take away.'**
  String get onboardingPrivacyBody;

  /// No description provided for @onboardingSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get onboardingSkip;

  /// No description provided for @onboardingNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get onboardingNext;

  /// No description provided for @onboardingStart.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get onboardingStart;

  /// No description provided for @chatMediaShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get chatMediaShare;

  /// No description provided for @chatMediaSaveToGallery.
  ///
  /// In en, this message translates to:
  /// **'Save to gallery'**
  String get chatMediaSaveToGallery;

  /// No description provided for @chatMediaShowInChat.
  ///
  /// In en, this message translates to:
  /// **'Show in chat'**
  String get chatMediaShowInChat;

  /// No description provided for @chatWallpaperTitle.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get chatWallpaperTitle;

  /// No description provided for @chatWallpaperClear.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get chatWallpaperClear;

  /// No description provided for @chatWallpaperDim.
  ///
  /// In en, this message translates to:
  /// **'Darken behind the messages'**
  String get chatWallpaperDim;

  /// No description provided for @chatSelectAction.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get chatSelectAction;

  /// No description provided for @chatForwardNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing here can be forwarded'**
  String get chatForwardNothing;

  /// No description provided for @chatSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 selected} other{{count} selected}}'**
  String chatSelectedCount(int count);

  /// No description provided for @chatDeleteSelectedTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete this message?} other{Delete {count} messages?}}'**
  String chatDeleteSelectedTitle(int count);

  /// No description provided for @contactAliasAction.
  ///
  /// In en, this message translates to:
  /// **'Rename contact'**
  String get contactAliasAction;

  /// No description provided for @contactAliasHint.
  ///
  /// In en, this message translates to:
  /// **'Only you see this name. Leave empty to use theirs.'**
  String get contactAliasHint;

  /// No description provided for @viewOnceSendLabel.
  ///
  /// In en, this message translates to:
  /// **'View once'**
  String get viewOnceSendLabel;

  /// No description provided for @viewOnceTitle.
  ///
  /// In en, this message translates to:
  /// **'View once'**
  String get viewOnceTitle;

  /// No description provided for @viewOnceTapToView.
  ///
  /// In en, this message translates to:
  /// **'Photo · tap to view once'**
  String get viewOnceTapToView;

  /// No description provided for @viewOnceOpened.
  ///
  /// In en, this message translates to:
  /// **'Photo opened'**
  String get viewOnceOpened;

  /// No description provided for @viewOnceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This photo is no longer available'**
  String get viewOnceUnavailable;

  /// No description provided for @viewOnceWarning.
  ///
  /// In en, this message translates to:
  /// **'Closing this deletes the photo for both of you.'**
  String get viewOnceWarning;

  /// No description provided for @channelAvatarAdminOnly.
  ///
  /// In en, this message translates to:
  /// **'Only an administrator can change the channel photo'**
  String get channelAvatarAdminOnly;

  /// No description provided for @channelAvatarTooLarge.
  ///
  /// In en, this message translates to:
  /// **'That photo is too large to broadcast'**
  String get channelAvatarTooLarge;

  /// No description provided for @channelMemberUnknown.
  ///
  /// In en, this message translates to:
  /// **'Not in your contacts yet'**
  String get channelMemberUnknown;

  /// No description provided for @channelPollTitle.
  ///
  /// In en, this message translates to:
  /// **'Poll'**
  String get channelPollTitle;

  /// No description provided for @channelCreatePoll.
  ///
  /// In en, this message translates to:
  /// **'Create poll'**
  String get channelCreatePoll;

  /// No description provided for @channelPollQuestion.
  ///
  /// In en, this message translates to:
  /// **'Question'**
  String get channelPollQuestion;

  /// No description provided for @channelPollOption.
  ///
  /// In en, this message translates to:
  /// **'Option {number}'**
  String channelPollOption(int number);

  /// No description provided for @channelPollAddOption.
  ///
  /// In en, this message translates to:
  /// **'Add option'**
  String get channelPollAddOption;

  /// No description provided for @channelPollCreate.
  ///
  /// In en, this message translates to:
  /// **'Publish poll'**
  String get channelPollCreate;

  /// No description provided for @channelPollVotes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No votes} =1{1 vote} other{{count} votes}}'**
  String channelPollVotes(int count);

  /// No description provided for @phoneTransferTitle.
  ///
  /// In en, this message translates to:
  /// **'Transfer to a new phone'**
  String get phoneTransferTitle;

  /// No description provided for @phoneTransferIntro.
  ///
  /// In en, this message translates to:
  /// **'Move your profile, keys, contacts, channels, settings and history directly between two phones.'**
  String get phoneTransferIntro;

  /// No description provided for @phoneTransferSend.
  ///
  /// In en, this message translates to:
  /// **'This is the old phone'**
  String get phoneTransferSend;

  /// No description provided for @phoneTransferReceive.
  ///
  /// In en, this message translates to:
  /// **'This is the new phone'**
  String get phoneTransferReceive;

  /// No description provided for @phoneTransferSameWifi.
  ///
  /// In en, this message translates to:
  /// **'Connect both phones to the same Wi-Fi. Keep this screen open until the transfer finishes.'**
  String get phoneTransferSameWifi;

  /// No description provided for @phoneTransferPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing encrypted transfer…'**
  String get phoneTransferPreparing;

  /// No description provided for @phoneTransferReady.
  ///
  /// In en, this message translates to:
  /// **'Scan this one-use QR code on the new phone'**
  String get phoneTransferReady;

  /// No description provided for @phoneTransferScan.
  ///
  /// In en, this message translates to:
  /// **'Scan old phone'**
  String get phoneTransferScan;

  /// No description provided for @phoneTransferConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace this phone’s profile?'**
  String get phoneTransferConfirmTitle;

  /// No description provided for @phoneTransferConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'The profile currently stored on this phone will be replaced by the encrypted local transfer.'**
  String get phoneTransferConfirmMessage;

  /// No description provided for @phoneTransferConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Transfer profile'**
  String get phoneTransferConfirmAction;

  /// No description provided for @phoneTransferSuccess.
  ///
  /// In en, this message translates to:
  /// **'Profile transferred successfully'**
  String get phoneTransferSuccess;

  /// No description provided for @phoneTransferFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not complete the phone transfer'**
  String get phoneTransferFailed;

  /// No description provided for @profileGroupConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get profileGroupConnection;

  /// No description provided for @profileGroupPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get profileGroupPrivacy;

  /// No description provided for @profileGroupData.
  ///
  /// In en, this message translates to:
  /// **'Sharing & data'**
  String get profileGroupData;

  /// No description provided for @profileGroupApp.
  ///
  /// In en, this message translates to:
  /// **'App'**
  String get profileGroupApp;

  /// No description provided for @profileSummaryMeshOnly.
  ///
  /// In en, this message translates to:
  /// **'Mesh only'**
  String get profileSummaryMeshOnly;

  /// No description provided for @profileSummaryMeshInternet.
  ///
  /// In en, this message translates to:
  /// **'Mesh · internet'**
  String get profileSummaryMeshInternet;

  /// No description provided for @profileSummaryBackgroundOn.
  ///
  /// In en, this message translates to:
  /// **'runs in background'**
  String get profileSummaryBackgroundOn;

  /// No description provided for @profileSummaryDiscoverable.
  ///
  /// In en, this message translates to:
  /// **'Discoverable'**
  String get profileSummaryDiscoverable;

  /// No description provided for @profileSummaryHidden.
  ///
  /// In en, this message translates to:
  /// **'Hidden'**
  String get profileSummaryHidden;

  /// No description provided for @profileSummaryLastSeenHidden.
  ///
  /// In en, this message translates to:
  /// **'last seen hidden'**
  String get profileSummaryLastSeenHidden;

  /// No description provided for @profileSummaryTransfersActive.
  ///
  /// In en, this message translates to:
  /// **'{count} in progress'**
  String profileSummaryTransfersActive(int count);

  /// No description provided for @profileSummaryCardBackup.
  ///
  /// In en, this message translates to:
  /// **'Contact card, files, backup'**
  String get profileSummaryCardBackup;

  /// No description provided for @chatPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get chatPlay;

  /// No description provided for @chatPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get chatPause;

  /// No description provided for @profileTheme.
  ///
  /// In en, this message translates to:
  /// **'Colour'**
  String get profileTheme;

  /// No description provided for @profileThemeEmerald.
  ///
  /// In en, this message translates to:
  /// **'Emerald'**
  String get profileThemeEmerald;

  /// No description provided for @profileThemeIndigo.
  ///
  /// In en, this message translates to:
  /// **'Indigo'**
  String get profileThemeIndigo;

  /// No description provided for @profileThemeAmber.
  ///
  /// In en, this message translates to:
  /// **'Amber'**
  String get profileThemeAmber;

  /// No description provided for @profileThemeRose.
  ///
  /// In en, this message translates to:
  /// **'Rose'**
  String get profileThemeRose;

  /// No description provided for @profileThemeFuchsia.
  ///
  /// In en, this message translates to:
  /// **'Fuchsia'**
  String get profileThemeFuchsia;

  /// No description provided for @profileThemeViolet.
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get profileThemeViolet;

  /// No description provided for @profileThemeOcean.
  ///
  /// In en, this message translates to:
  /// **'Ocean'**
  String get profileThemeOcean;

  /// No description provided for @profileThemeSlate.
  ///
  /// In en, this message translates to:
  /// **'Slate'**
  String get profileThemeSlate;

  /// No description provided for @profileScale.
  ///
  /// In en, this message translates to:
  /// **'Interface size'**
  String get profileScale;

  /// No description provided for @profileScaleSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get profileScaleSystem;

  /// No description provided for @profileScaleSmall.
  ///
  /// In en, this message translates to:
  /// **'Smaller'**
  String get profileScaleSmall;

  /// No description provided for @profileScaleNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get profileScaleNormal;

  /// No description provided for @profileScaleLarge.
  ///
  /// In en, this message translates to:
  /// **'Larger'**
  String get profileScaleLarge;

  /// No description provided for @profileScaleSample.
  ///
  /// In en, this message translates to:
  /// **'Text and rows are drawn at this size.'**
  String get profileScaleSample;

  /// No description provided for @savedTitle.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get savedTitle;

  /// No description provided for @savedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Notes to yourself, on this device'**
  String get savedSubtitle;

  /// No description provided for @savedEmpty.
  ///
  /// In en, this message translates to:
  /// **'Anything you write here stays on this phone.'**
  String get savedEmpty;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'uk'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'uk':
      return AppLocalizationsUk();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
