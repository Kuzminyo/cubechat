import 'package:flutter/widgets.dart';

/// Tiny process-wide flag for "is the app currently in the foreground".
///
/// Set from the root widget's lifecycle observer; read by the messaging layer
/// to decide whether an incoming message warrants a system notification (we
/// don't notify while the user is actively looking at the app), and by the
/// presence beacon, for which it is the whole meaning of "online".
class AppLifecycle {
  AppLifecycle._();
  static final AppLifecycle instance = AppLifecycle._();

  /// What the lifecycle observer last saw. Starts false: the engine is
  /// pre-warmed headless in MainApplication, so until an Activity resumes we
  /// are NOT in the foreground.
  bool _observed = false;

  /// True while the app is on screen.
  ///
  /// The observer is not trusted on its own for a "no". It is told about
  /// *transitions*, and on Android the engine is pre-warmed headless — so the
  /// process can be born outside any lifecycle, the seed reads nothing, and an
  /// Activity that attaches without a transition this observer sees leaves the
  /// flag stuck at false for the whole session. A phone in that state never
  /// claims to be online however long its owner uses it, while the identical
  /// build on another phone is fine because there the callback happened to
  /// arrive. Both were in a pair of field logs.
  ///
  /// The framework's own view of the lifecycle does not depend on our observer
  /// having been listening at the right moment, so it is the second opinion —
  /// consulted only to *promote* to foreground, never to demote, which keeps
  /// "we were told we left" authoritative.
  bool get isForeground =>
      _observed ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  set isForeground(bool value) => _observed = value;

  /// Canonical id (pubkey-hex) of the chat the user is currently viewing, or
  /// null if no chat is open. An inbound message is shown as a system
  /// notification UNLESS the user is actively looking at that exact chat
  /// (foreground + this chat open).
  String? activeChatId;

  /// True when an inbound message for [canonicalId] should NOT pop a
  /// notification — i.e. the user is right there reading it.
  bool isViewingChat(String canonicalId) =>
      isForeground && activeChatId == canonicalId;

  /// True while the Nearby tab is the branch actually on screen.
  ///
  /// Set from the screen itself off [TickerMode], because the tab shell keeps
  /// every branch mounted for the life of the session — "did initState run" says
  /// nothing about whether anyone is looking at it.
  ///
  /// Read by the scanner to decide the scan cadence. Being in the foreground
  /// used to be enough to scan hard, which meant reading a conversation for ten
  /// minutes held the Android radio at a 71% duty cycle to populate a radar
  /// nobody was looking at. Discovery is only worth the active cadence when
  /// someone is watching it happen.
  bool isWatchingNearby = false;

  /// True only while the live-map branch is actually painted. Location fixes
  /// and map beacons are gated on this so a mounted-but-offstage tab cannot
  /// keep GPS or the network awake.
  bool isWatchingMap = false;
}
