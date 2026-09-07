import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../storage/hive_cipher.dart';
import '../../storage/hive_init.dart';

/// Persists the `created_at` of the newest Nostr event we've accepted, so the
/// relay subscription resumes where it left off instead of re-downloading the
/// stored backlog on every app launch.
///
/// Kept in the shared (encrypted) settings box: the value is a timestamp, but
/// "when did this device last receive off-mesh mail" is still metadata worth
/// encrypting at rest, and living in that box means Emergency Wipe takes it out
/// along with everything else.
class RelayWatermarkStore {
  static const key = 'nostr.since';

  /// Event ids already accepted, so a replay costs a set lookup.
  ///
  /// The subscription deliberately asks for ten minutes *before* the
  /// watermark — a sender whose clock trails ours can stamp an event below a
  /// mark we have passed, and the overlap is what stops that message being
  /// skipped. The comment beside it called re-downloading a few minutes of
  /// backlog "cheap and harmless", which is true of a 289-byte text frame and
  /// not of a 32 kB media chunk.
  ///
  /// Two consecutive launches, measured from a shipped log: six images and
  /// 1.43 MB reassembled, three of them already on disk; then ten images and
  /// 2.33 MB, six already on disk — **1.43 MB, 61% of it, thrown away.** Same
  /// six hashes both times. And thrown away at the *end*: every chunk
  /// buffered, the signature checked, the file assembled and SHA-256'd, and
  /// only then found to be a duplicate.
  ///
  /// The pool already keeps these ids in memory to de-duplicate across
  /// relays, and the gate that reads them sits before verification — so
  /// carrying them across a restart skips all of that work rather than some
  /// of it. The bytes still arrive: the relay sends what our filter asks for,
  /// and narrowing the filter is the correctness trade this exists to avoid.
  static const idsKey = 'nostr.seen';

  Box<dynamic>? _box;

  /// The persisted watermark in unix seconds, or null if we've never accepted an
  /// event (or the box can't be opened — then we simply take the full backlog,
  /// which the message store dedups).
  Future<int?> load() async {
    try {
      final box = _box ??= await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      return box.get(key) as int?;
    } catch (e) {
      debugPrint('Relay watermark load failed: $e');
      return null;
    }
  }

  /// Store [seconds]. Called on every advance; monotonic, so an out-of-order
  /// call can't walk the watermark backwards and re-open the backlog.
  Future<void> save(int seconds) async {
    try {
      final box = _box ??= await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final current = box.get(key) as int?;
      if (current != null && seconds <= current) return;
      await box.put(key, seconds);
    } catch (e) {
      debugPrint('Relay watermark persist failed: $e');
    }
  }

  /// Event ids accepted on a previous run, oldest first.
  Future<List<String>> loadSeenIds() async {
    try {
      final box = _box ??= await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = box.get(idsKey);
      if (raw is! List) return const <String>[];
      return <String>[
        for (final v in raw)
          if (v is String && v.isNotEmpty) v,
      ];
    } catch (e) {
      debugPrint('Relay seen-ids load failed: $e');
      return const <String>[];
    }
  }

  /// Replace the remembered ids. Called on a debounce rather than per event —
  /// this is a hundred-odd kilobytes and a relay backlog arrives in bursts.
  Future<void> saveSeenIds(List<String> ids) async {
    try {
      final box = _box ??= await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put(idsKey, ids);
    } catch (e) {
      debugPrint('Relay seen-ids persist failed: $e');
    }
  }
}
