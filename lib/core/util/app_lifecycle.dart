/// Tiny process-wide flag for "is the app currently in the foreground".
///
/// Set from the root widget's lifecycle observer; read by the messaging layer
/// to decide whether an incoming message warrants a system notification (we
/// don't notify while the user is actively looking at the app).
class AppLifecycle {
  AppLifecycle._();
  static final AppLifecycle instance = AppLifecycle._();

  /// Defaults to false: the engine is pre-warmed headless in MainApplication,
  /// so until an Activity resumes we are NOT in the foreground.
  bool isForeground = false;

  /// Canonical id (pubkey-hex) of the chat the user is currently viewing, or
  /// null if no chat is open. An inbound message is shown as a system
  /// notification UNLESS the user is actively looking at that exact chat
  /// (foreground + this chat open).
  String? activeChatId;

  /// True when an inbound message for [canonicalId] should NOT pop a
  /// notification — i.e. the user is right there reading it.
  bool isViewingChat(String canonicalId) =>
      isForeground && activeChatId == canonicalId;
}
