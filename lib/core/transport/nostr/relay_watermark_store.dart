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
}
