import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Ceiling on a channel description/topic, in UTF-16 code units. Generous for
/// a one-line topic, well short of anything that would make the broadcast
/// frame worth fragmenting.
const int kChannelDescriptionMaxLength = 500;

/// Channel descriptions, keyed by channel name.
///
/// Same trust model as [ChannelAvatarsController]: a room has no key of its
/// own to sign against, so what stands in for that is the sender — a channel
/// frame is signed by whoever sent it, and only a member the roster already
/// knows to be an admin is allowed to set the topic. See the
/// `channelDescription` case in `MessagingService`.
class ChannelDescriptionsController extends Notifier<Map<String, String>> {
  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, String> build() {
    unawaited(_loading = _load());
    return const <String, String>{};
  }

  String? forChannel(String name) => state[name];

  /// Set a room's topic. Returns false when it is too long to carry in one
  /// broadcast frame — a description is broadcast, never requested.
  Future<bool> store(String name, String text) async {
    final trimmed = text.trim();
    if (trimmed.length > kChannelDescriptionMaxLength) return false;
    if (trimmed.isEmpty) {
      await forget(name);
      return true;
    }
    state = {...state, name: trimmed};
    try {
      await _box?.put(name, trimmed);
    } catch (e) {
      debugPrint('ChannelDescriptions persist failed: $e');
    }
    return true;
  }

  /// Drop a room's topic — it was cleared, or we left the room.
  Future<void> forget(String name) async {
    if (!state.containsKey(name)) return;
    state = {...state}..remove(name);
    try {
      await _box?.delete(name);
    } catch (e) {
      debugPrint('ChannelDescriptions forget failed: $e');
    }
  }

  /// Back to nothing — Emergency Wipe.
  Future<void> clear() async {
    state = const <String, String>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('ChannelDescriptions clear failed: $e');
    }
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.channelDescriptions);
      _box = box;
      final loaded = <String, String>{};
      for (final key in box.keys) {
        if (key is! String) continue;
        final raw = box.get(key);
        if (raw is String && raw.isNotEmpty) loaded[key] = raw;
      }
      if (loaded.isNotEmpty) state = {...loaded, ...state};
    } catch (e) {
      debugPrint('ChannelDescriptions load failed: $e');
    }
  }
}

final channelDescriptionsControllerProvider = NotifierProvider<
    ChannelDescriptionsController,
    Map<String, String>>(
  ChannelDescriptionsController.new,
);
