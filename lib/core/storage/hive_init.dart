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
  /// Joined group channels (name + derived symmetric key). Encrypted at rest
  /// because the key grants read/write access to the channel.
  static const channels = 'cubechat.channels';

  /// Forward-secret signed prekey private material.
  static const prekeys = 'cubechat.prekeys';

  /// Avatar thumbnails received from peers, keyed by pubkey hex.
  ///
  /// Its own box rather than a field on [knownPeers]: the roster is read whole
  /// on every load and written whole on every `lastSeen` touch, and a few KB of
  /// JPEG per contact would ride along with each of those.
  static const peerAvatars = 'cubechat.peer_avatars';

  /// Channel pictures, keyed by channel name. Separate from [channels] for the
  /// same reason [peerAvatars] is separate from [knownPeers]: that box holds
  /// the room key and is read and rewritten far more often than a picture
  /// changes.
  static const channelAvatars = 'cubechat.channel_avatars';

  /// Channel topics, keyed by channel name. Same reasoning as
  /// [channelAvatars] — small, changes rarely, and the [channels] box is read
  /// whole on every load.
  static const channelDescriptions = 'cubechat.channel_descriptions';

  /// What you call a contact, keyed by pubkey hex. Its own box for the reason
  /// [ContactAliasesController] documents: [knownPeers] is rewritten on every
  /// announcement, and an alias must not ride along with something that
  /// churns.
  static const contactAliases = 'cubechat.contact_aliases';

  /// The stickers this person keeps, as paths into app storage. Only the paths
  /// live here — the pictures themselves are files, for the same reason peer
  /// avatars are: a box that is read on every keystroke of a picker has no
  /// business carrying a few hundred kilobytes of PNG.
  static const stickers = 'cubechat.stickers';

  static const all = <String>[
    knownPeers,
    messages,
    settings,
    relayBuffer,
    channels,
    prekeys,
    peerAvatars,
    channelAvatars,
    channelDescriptions,
    contactAliases,
    stickers,
  ];
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
        // Straight to the delete, which closes the box itself if it is open.
        //
        // What stood here first asked for `Hive.box<dynamic>(name)`, and that
        // insists on the exact type the box was opened with — ours are opened
        // as `Box<Map<...>>` and `Box<List<...>>`, so it threw "already open
        // and of type ..." on every one of them, took the delete down with it
        // into the catch, and left the box on disk untouched. Visible as a
        // phone transfer that arrived and changed nothing: the old contacts,
        // pins and nickname were never cleared, so the imported ones had
        // nowhere to land.
        await Hive.deleteBoxFromDisk(name);
      } catch (e) {
        debugPrint('Hive wipe of box "$name" failed: $e');
      }
    }
  }
}
