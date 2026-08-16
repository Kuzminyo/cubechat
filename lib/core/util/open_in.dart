import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

import 'debug_log.dart';
import 'platform_info.dart';

/// Give a file to another app, and go there.
///
/// iOS only, and deliberately not a replacement for the share sheet. The two
/// are different mechanisms with different outcomes:
///
///   * `Share.shareXFiles` presents `UIActivityViewController`, which runs the
///     chosen app's *share extension* — a window belonging to that app, drawn
///     over cubechat. The phone never leaves this app. That is the platform's
///     design and no flag turns it off.
///   * This presents `UIDocumentInteractionController`'s "Open in…" menu, which
///     copies the file into the target app and launches it. The phone changes
///     apps, which is what people mean when they say "send it to Telegram".
///
/// Only apps that declare they handle the file's type appear in that menu, so
/// it can legitimately come up empty — [handOff] answers false and the caller
/// falls back to the sheet rather than leaving a tap that did nothing.
///
/// Android needs none of this: a share intent already resolves to the real app.
class OpenIn {
  const OpenIn._();

  static const MethodChannel channel = MethodChannel('cubechat/open_in');

  /// Whether the platform has a hand-off distinct from the share sheet at all.
  ///
  /// Android does too, and for a different reason than iOS. There the sheet
  /// runs the target's share *extension* over this app; here it launches the
  /// target's activity into cubechat's own task, because share_plus starts it
  /// without FLAG_ACTIVITY_NEW_TASK — so picking Telegram put Telegram inside a
  /// recents card wearing cubechat's icon. MainActivity's handler sets the flag
  /// and the chosen app opens as itself. Both platforms answer the same
  /// question: does the phone actually go to the other app.
  static bool get isSupported => PlatformInfo.isIOS || PlatformInfo.isAndroid;

  /// Offer a line of text — a contact card, a link — to another app.
  ///
  /// Android only. iOS has no document-interaction equivalent for text, and it
  /// does not need one: the share sheet's behaviour there is the platform's
  /// own, while on Android the sheet leaves the chosen app inside cubechat's
  /// task. False means the caller should fall back to the sheet.
  static Future<bool> handOffText(String text, {String? subject}) async {
    if (!PlatformInfo.isAndroid) return false;
    try {
      final shown = await channel.invokeMethod<bool>('openInText', {
        'text': text,
        'subject': subject,
      });
      return shown ?? false;
    } catch (e) {
      DebugLog.instance.log('SHARE', 'text hand-off unavailable: $e');
      return false;
    }
  }

  /// Offer [path] to the apps that can open it. Returns whether the menu was
  /// actually shown.
  ///
  /// [anchor] is where the menu points, in logical pixels — the same rect the
  /// share sheet needs, and needed for the same reason: UIKit presents this as
  /// a popover and refuses an empty or off-screen source. Use `shareAnchorFor`
  /// to measure the control that was tapped.
  static Future<bool> handOff(String path, {required Rect anchor}) async {
    if (!isSupported) return false;
    try {
      final shown = await channel.invokeMethod<bool>('openIn', {
        'path': path,
        'anchor': {
          'x': anchor.left,
          'y': anchor.top,
          'width': anchor.width,
          'height': anchor.height,
        },
      });
      return shown ?? false;
    } catch (e) {
      // A build without the plugin registered raises MissingPluginException;
      // everything else arrives as a PlatformException. Neither is worth
      // failing the user's tap over when there is a share sheet behind it.
      DebugLog.instance.log('SHARE', 'open-in unavailable: $e');
      return false;
    }
  }
}
