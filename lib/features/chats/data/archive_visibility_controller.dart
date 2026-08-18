import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Whether the archive row is shown at the top of the chat list.
///
/// The drawer already hides itself while it is empty, which covers the person
/// who has never used it. This covers the other one: somebody who archived a
/// few conversations on purpose and does not want a permanent row about them
/// sitting above the chats they actually read. Telegram lets that row be put
/// away and so does this.
///
/// Hidden means hidden, not gone — every archived conversation still receives,
/// and its unread still counts. The way back is the switch in Customisation,
/// which is where every other decision about the shape of this app lives, and
/// the toast shown on the way out says so. A gesture-only escape hatch would
/// be a row nobody could find again.
class ArchiveVisibilityController extends Notifier<bool> {
  static const _key = 'chats.archive_visible';

  Box<dynamic>? _box;

  /// Visible until told otherwise — an install that has never touched this
  /// must look exactly as it did before the setting existed.
  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final saved = box.get(_key);
      if (saved is bool && saved != state) state = saved;
    } catch (e) {
      debugPrint('ArchiveVisibility load failed: $e');
    }
  }

  Future<void> set(bool visible) async {
    if (visible == state) return;
    state = visible;
    try {
      await _box?.put(_key, visible);
    } catch (e) {
      debugPrint('ArchiveVisibility persist failed: $e');
    }
  }

  Future<void> toggle() => set(!state);
}

final archiveVisibleProvider =
    NotifierProvider<ArchiveVisibilityController, bool>(
  ArchiveVisibilityController.new,
);
