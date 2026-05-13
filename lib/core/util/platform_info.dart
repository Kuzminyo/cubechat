import 'package:flutter/foundation.dart';

/// Web-safe platform detection.
///
/// `dart:io`'s `Platform` class throws on web at runtime and (in some build
/// modes) won't even compile there. Anywhere we need to ask "is this Android"
/// or "is this iOS" from shared Dart code that may run on web, we route the
/// question through here.
abstract final class PlatformInfo {
  static bool get isWeb => kIsWeb;
  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get isMobile => isAndroid || isIOS;
}
