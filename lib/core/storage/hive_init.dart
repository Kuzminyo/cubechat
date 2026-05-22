import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Hive box names. Centralised so a wipe can iterate them in one place.
abstract final class HiveBoxes {
  static const knownPeers = 'cubechat.known_peers';
  static const messages = 'cubechat.messages';
  /// User preferences: nickname, etc.
  static const settings = 'cubechat.settings';
  /// Opportunistic store-and-forward relay buffer (encrypted frames held
  /// for currently-unreachable peers). Survives restart within the 1h TTL.
  static const relayBuffer = 'cubechat.relay_buffer';

  static const all = <String>[knownPeers, messages, settings, relayBuffer];
}

/// Initialises Hive. Call from `main()` after `WidgetsFlutterBinding.
/// ensureInitialized()` and before `runApp(...)`. Boxes are opened lazily
/// by the controllers that own them.
class HiveInit {
  static bool _done = false;

  static Future<void> ensureInitialized() async {
    if (_done) return;
    _done = true;
    if (kIsWeb) {
      // hive_flutter's web path uses IndexedDB; no directory needed.
      await Hive.initFlutter();
    } else {
      final dir = await getApplicationSupportDirectory();
      Hive.init(dir.path);
    }
  }

  /// Closes + deletes every cubechat-owned Hive box. Used by Emergency Wipe.
  /// Safe to call before the boxes are opened by callers — Hive ignores
  /// box names it doesn't know about.
  static Future<void> wipeAll() async {
    for (final name in HiveBoxes.all) {
      try {
        if (Hive.isBoxOpen(name)) {
          await Hive.box<dynamic>(name).clear();
          await Hive.box<dynamic>(name).close();
        }
        await Hive.deleteBoxFromDisk(name);
      } catch (e) {
        debugPrint('Hive wipe of box "$name" failed: $e');
      }
    }
  }
}
