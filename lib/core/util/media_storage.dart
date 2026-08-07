import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'debug_log.dart';

/// Where conversation media lives on disk.
///
/// **Not the cache directory.** Photos, voice notes and files are the
/// conversation — there is no server holding a second copy, so a picture the
/// OS evicts is a picture gone for good, and the bubble that pointed at it
/// becomes a permanent dead end.
///
/// That is exactly what was happening: received images, received voice notes,
/// your own recordings and your own sent photos all went to
/// `getApplicationCacheDirectory()`, which Android and iOS are free to empty
/// whenever they want space — typically within a day or two. Received *files*
/// were always kept under Documents, which is why those survived while
/// everything else quietly stopped opening.
///
/// Documents rather than Support, to match the inbox and outbox that were
/// already there, so there is one place for all of it.
Future<Directory> mediaDirectory(String name) async {
  final root = await getApplicationDocumentsDirectory();
  final dir = Directory('${root.path}${Platform.pathSeparator}$name');
  try {
    if (!await dir.exists()) await dir.create(recursive: true);
  } catch (e) {
    // Named, because a media directory that cannot be created turns every
    // photo and voice note in the app into "no longer available" with nothing
    // in the log to say why.
    DebugLog.instance.log('MEDIA', 'cannot create ${dir.path}: $e');
    rethrow;
  }
  return dir;
}

/// Re-points a stored media path at wherever the app lives *now*.
///
/// Every path in the message store is absolute, and on iOS the container they
/// were absolute *to* does not survive a reinstall — which for a sideloaded
/// app is every seven days, when the signature is refreshed. The bytes are
/// still on disk under the new container; only the recorded path is stale, and
/// the bubble reports "no longer available" over a file that is right there.
///
/// So the path is treated as a hint rather than an address: if it still
/// resolves it is used unchanged, and if it does not, the last two segments —
/// which is always `cubechat-something/name.ext` for anything this app wrote —
/// are rebuilt against the current directory. Repairing on read rather than
/// migrating means nothing has to be moved, and a history written by any
/// earlier build heals itself the first time it is opened.
class MediaPaths {
  static String? _documentsRoot;

  /// Resolved once at boot, because the repair below has to be synchronous —
  /// it runs inside the message decoder and inside widget builds.
  static Future<void> init() async {
    try {
      _documentsRoot = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      // Leaves [repair] a no-op, which is the pre-existing behaviour.
    }
  }

  static String repair(String stored) {
    final root = _documentsRoot;
    if (root == null || stored.isEmpty) return stored;
    if (stored.startsWith(root)) return stored;
    final parts = stored.split(RegExp(r'[\\/]'));
    if (parts.length < 2) return stored;
    final sep = Platform.pathSeparator;
    final rebased =
        '$root$sep${parts[parts.length - 2]}$sep${parts[parts.length - 1]}';
    return exists(rebased) ? rebased : stored;
  }

  /// Null-tolerant, for the three optional path fields on a message.
  static String? repairOrNull(String? stored) =>
      stored == null ? null : repair(stored);

  // ---- memoized existence ----
  //
  // `existsSync()` is a blocking syscall, and every one of its callers asks
  // from inside a widget build: the image bubble opens with it, and so do the
  // voice bubble, the pinned bar, the wallpaper layer and [repair] itself.
  //
  // A build is not a rare event. While a chat is scrolled, or a page slides
  // under the back gesture, every visible bubble rebuilds on every frame — so a
  // screen holding eight photos asked the filesystem eight questions per frame,
  // ~960 of them a second at 120 Hz, and the answer had not changed since the
  // app launched. That is the tearing under the swipe, the stutter when a chat
  // opens, and on Android it is heat: the syscall blocks the UI isolate, so the
  // frame budget is spent waiting on storage instead of drawing.
  //
  // So the answer is remembered. [_ttl] is long enough that no animation ever
  // pays for the same question twice, and short enough that a file appearing or
  // vanishing behind the app's back corrects itself while the user is still
  // looking at the screen. Anything this app deletes itself calls [forget], so
  // a burned view-once photo reads as gone immediately rather than at the end
  // of the window.

  static final Map<String, _Existence> _existsCache = <String, _Existence>{};

  /// Monotonic, unlike `DateTime.now()` — a clock change must not extend or
  /// expire a cached answer.
  static final Stopwatch _clock = Stopwatch()..start();

  static const int _ttlMs = 2000;

  /// Only ever a few dozen paths are on screen at once; the ceiling exists so a
  /// long scroll through a media-heavy history cannot grow this without bound.
  static const int _maxEntries = 512;

  /// `File(path).existsSync()`, answered from memory when it was asked
  /// recently. Safe to call from `build`.
  static bool exists(String path) {
    if (path.isEmpty) return false;
    final now = _clock.elapsedMilliseconds;
    final hit = _existsCache[path];
    if (hit != null && now - hit.askedAt < _ttlMs) return hit.value;
    final value = File(path).existsSync();
    if (_existsCache.length >= _maxEntries) _existsCache.clear();
    _existsCache[path] = _Existence(value, now);
    return value;
  }

  /// Null-tolerant, matching [repairOrNull].
  static bool existsOrNull(String? path) => path != null && exists(path);

  /// Drop a remembered answer, for the moment the app itself creates or
  /// destroys the file and cannot wait out [_ttlMs] to say so.
  static void forget(String? path) {
    if (path != null) _existsCache.remove(path);
  }

  /// After an Emergency Wipe, or anything else that clears media wholesale.
  static void forgetAll() => _existsCache.clear();

  @visibleForTesting
  static void resetCacheForTest() => _existsCache.clear();
}

class _Existence {
  const _Existence(this.value, this.askedAt);
  final bool value;
  final int askedAt;
}

/// Received photos.
Future<Directory> receivedImagesDirectory() =>
    mediaDirectory('cubechat-images');

/// Voice notes — both the ones that arrive and the ones recorded here. They
/// share a directory because they are the same kind of thing and are named by
/// a unique id either way.
Future<Directory> voiceDirectory() => mediaDirectory('cubechat-audio');

/// Copies of photos sent from this device, so an outgoing bubble has something
/// to render.
Future<Directory> sentImagesDirectory() => mediaDirectory('cubechat-sent');
