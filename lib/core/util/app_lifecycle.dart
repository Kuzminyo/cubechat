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
}
