import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/inner_payload.dart';

/// Channel pictures, keyed by channel name.
///
/// Unlike a peer's avatar there is no signed announcement to check the bytes
/// against — a room has no key of its own to commit with. What stands in for it
/// is the sender: a channel frame is signed by whoever sent it, and only a
/// member the roster already knows to be an admin is allowed to set the
/// picture. See the `channelAvatar` case in `MessagingService`.
class ChannelAvatarsController extends Notifier<Map<String, Uint8List>> {
  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, Uint8List> build() {
    unawaited(_loading = _load());
    return const <String, Uint8List>{};
  }

  Uint8List? forChannel(String name) => state[name];

  /// Cache a room's picture. Returns false when the bytes are empty or beyond
  /// what one frame carries — a channel avatar is broadcast, never requested,
  /// so it has to fit a single [AvatarPayload].
  Future<bool> store(String name, Uint8List jpeg) async {
    if (jpeg.isEmpty || jpeg.length > AvatarPayload.maxBytes) return false;
    state = {...state, name: jpeg};
    try {
      await _box?.put(name, jpeg);
    } catch (e) {
      debugPrint('ChannelAvatars persist failed: $e');
    }
    return true;
  }

  /// Drop a room's picture — it was cleared, or we left the room.
  Future<void> forget(String name) async {
    if (!state.containsKey(name)) return;
    state = {...state}..remove(name);
    try {
      await _box?.delete(name);
    } catch (e) {
      debugPrint('ChannelAvatars forget failed: $e');
    }
  }

  /// Back to nothing — Emergency Wipe.
  Future<void> clear() async {
    state = const <String, Uint8List>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('ChannelAvatars clear failed: $e');
    }
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.channelAvatars);
      _box = box;
      final loaded = <String, Uint8List>{};
      for (final key in box.keys) {
        if (key is! String) continue;
        final raw = box.get(key);
        if (raw is Uint8List && raw.isNotEmpty) {
          loaded[key] = raw;
        } else if (raw is List<int> && raw.isNotEmpty) {
          // Hive can hand back a plain List<int> depending on how it was
          // written.
          loaded[key] = Uint8List.fromList(raw);
        }
      }
      if (loaded.isNotEmpty) state = {...loaded, ...state};
    } catch (e) {
      debugPrint('ChannelAvatars load failed: $e');
    }
  }
}

final channelAvatarsControllerProvider =
    NotifierProvider<ChannelAvatarsController, Map<String, Uint8List>>(
  ChannelAvatarsController.new,
);
