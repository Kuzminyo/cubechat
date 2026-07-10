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
