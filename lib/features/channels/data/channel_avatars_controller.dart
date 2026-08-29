import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/identity/avatar_controller.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/inner_payload.dart';
import '../models/channel.dart';

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

  /// A room's picture, falling back to the channel it discusses.
  ///
  /// A discussion room has no picture of its own and nobody to set one: it is
  /// derived rather than created, so it never gets an avatar broadcast, and it
  /// sat in the chat list as a grey initial beside the channel it belongs to.
  /// It is the same room to a reader, so it wears the same face.
  Uint8List? forChannel(String name) {
    final own = state[name];
    if (own != null) return own;
    final parent = channelForCommunity(name);
    return parent == null ? null : state[parent];
  }

  /// Cache a room's picture. Returns false when the bytes are empty or beyond
  /// what one frame carries — a channel avatar is broadcast, never requested,
  /// so it has to fit a single [AvatarPayload].
  Future<bool> store(String name, Uint8List jpeg) async {
    // Whatever the room's picture actually is. The old ceiling was the size of
    // a single broadcast frame, which is a fact about the fragmenter and not
    // about a picture — and it is no longer even that, since a larger one is
    // chunked. Kept as a sanity bound rather than a format rule.
    if (jpeg.isEmpty || jpeg.length > AvatarController.shareByteBudget) {
      return false;
    }
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
