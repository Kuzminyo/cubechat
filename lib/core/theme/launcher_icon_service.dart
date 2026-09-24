import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/debug_log.dart';

/// Keeps the home-screen icon in step with the chosen palette.
///
/// Android enables one `activity-alias` per icon and disables the rest (see
/// the manifest); iOS switches to an alternate icon compiled from the asset
/// catalog, and shows its own "you have changed the icon" alert when it does.
/// Only the eight built-in icons exist — a hue picked from the wheel gets the
/// nearest of them.
///
/// Called only when the icon actually has to change, never on every start:
/// on Android each switch is a component enable/disable, and some launchers
/// drop the pinned home-screen shortcut of a component that was toggled. The
/// native side is idempotent as well, as a second line.
abstract final class LauncherIconService {
  static const _channel = MethodChannel('cubechat/launcher_icon');

  /// The icon a fresh install shows: the enabled-by-default alias on Android,
  /// the primary `AppIcon` on iOS.
  static const defaultIcon = 'emerald';

  /// Every icon the platforms carry, in the palette picker's order.
  static const icons = <String>[
    'emerald',
    'indigo',
    'amber',
    'rose',
    'fuchsia',
    'violet',
    'ocean',
    'slate',
  ];

  /// Hues of the coloured icons, measured off each palette's `brandPrimary`.
  /// Slate is left out on purpose: it is the colourless one, and a saturated
  /// blue picked from the wheel should not come out grey.
  static const _hues = <String, double>{
    'amber': 37,
    'emerald': 153,
    'ocean': 191,
    'indigo': 233,
    'violet': 267,
    'fuchsia': 336,
    'rose': 340,
  };

  /// Only the phones have a launcher to change. Desktop and web builds are for
  /// UI work and carry no handler for the channel.
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Which icon [paletteId] should show. Unknown ids fall back to the default,
  /// the same way `AppPalette.byId` falls back to Emerald.
  static String iconFor(String paletteId) {
    if (icons.contains(paletteId)) return paletteId;
    const prefix = 'hue:';
    if (!paletteId.startsWith(prefix)) return defaultIcon;
    final hue = double.tryParse(paletteId.substring(prefix.length));
    if (hue == null) return defaultIcon;
    final h = hue % 360;
    var best = defaultIcon;
    var bestDistance = double.infinity;
    for (final entry in _hues.entries) {
      final direct = (h - entry.value).abs();
      final distance = direct > 180 ? 360 - direct : direct;
      if (distance < bestDistance) {
        best = entry.key;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// Which icon the launcher shows now, or null when the platform cannot say.
  /// A read only — it toggles nothing.
  static Future<String?> current() async {
    if (!supported) return null;
    try {
      final icon = await _channel.invokeMethod<String>('currentIcon');
      return icons.contains(icon) ? icon : null;
    } on MissingPluginException {
      return null;
    } catch (e) {
      DebugLog.instance.log('theme', 'launcher icon read failed: $e');
      return null;
    }
  }

  /// Asks the platform to show [icon]. True when the platform confirmed it.
  static Future<bool> apply(String icon) async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setIcon',
        <String, String>{'icon': icon},
      );
      DebugLog.instance.log(
        'theme',
        ok == true ? 'launcher icon -> $icon' : 'launcher icon $icon refused',
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      DebugLog.instance.log('theme', 'launcher icon $icon failed: $e');
      return false;
    }
  }
}
