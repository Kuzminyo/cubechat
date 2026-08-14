import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/util/image_encode.dart';
import '../../../core/util/media_storage.dart';

/// The stickers this person keeps, newest first, as paths into app storage.
///
/// There is no sticker *server* and there will not be one: a pack is whatever
/// pictures somebody has kept, and it grows the way everything else here
/// does — from the conversation. A sticker you are sent can be kept with one
/// tap, and a picture of your own becomes a sticker the same way.
///
/// Only the paths are stored. The pictures are files, because this box is read
/// every time the picker opens and a box carrying a few hundred kilobytes of
/// PNG per sticker would be read into memory whole, every time.
class StickerLibrary extends Notifier<List<String>> {
  static const _key = 'sticker_paths';

  /// What each sticker is called, keyed by path. Its own entry rather than a
  /// field on the path list so a library written by an older build still loads:
  /// the paths are the sticker, the emoji is a label on it.
  static const _emojiKey = 'sticker_emoji';

  /// A cap, so a library nobody prunes cannot grow without limit. Oldest goes
  /// when the newest arrives — the same rule a recents row has always used.
  static const int maxStickers = 120;

  Box<dynamic>? _box;

  final Map<String, String> _emoji = <String, String>{};

  @override
  List<String> build() {
    unawaited(_load());
    return const <String>[];
  }

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.stickers);
      _box = box;
      final raw = box.get(_key);
      if (raw is! List) return;
      // Repaired on read: iOS moves the container between launches, so a path
      // stored yesterday can name a directory that no longer exists. Same
      // treatment every stored media path gets.
      final paths = <String>[];
      for (final entry in raw.whereType<String>()) {
        final repaired = MediaPaths.repair(entry);
        if (File(repaired).existsSync()) paths.add(repaired);
      }
      final labels = box.get(_emojiKey);
      if (labels is Map) {
        for (final entry in labels.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is String && value is String) {
            _emoji[MediaPaths.repair(key)] = value;
          }
        }
      }
      if (paths.isNotEmpty) state = paths;
    } catch (e) {
      debugPrint('StickerLibrary load failed: $e');
    }
  }

  bool has(String path) => state.contains(MediaPaths.repair(path));

  /// The emoji this sticker was filed under, or null for one kept before there
  /// were any.
  String? emojiFor(String path) => _emoji[MediaPaths.repair(path)];

  /// Keep a picture already on disk — one that arrived in a message.
  Future<bool> keep(String sourcePath, {String? emoji}) async {
    final source = File(MediaPaths.repair(sourcePath));
    if (!await source.exists()) return false;
    return keepBytes(await source.readAsBytes(), emoji: emoji);
  }

  /// Keep bytes that are not a file yet — one the user just picked or drew.
  ///
  /// The picture is turned into a sticker on the way in rather than on the way
  /// out: trimmed to what it draws, scaled to sticker size and re-encoded as
  /// PNG. Kept raw, a photo saved from a chat is a couple of megabytes of JPEG,
  /// and every send of it would push that through the mesh — the one place in
  /// this app where the difference is measured in minutes rather than
  /// milliseconds. Doing it here also means it is done once per sticker instead
  /// of once per send.
  ///
  /// False when the picture could not be encoded small enough to travel, so the
  /// caller can say so instead of filling the library with things that cannot
  /// be sent.
  Future<bool> keepBytes(Uint8List bytes, {String? emoji}) async {
    final png = await encodeStickerPng(bytes);
    if (png == null) return false;
    await _store(png, emoji);
    return true;
  }

  Future<void> _store(Uint8List bytes, [String? emoji]) async {
    try {
      final dir = await mediaDirectory('cubechat-stickers');
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        's${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);
      if (emoji != null && emoji.isNotEmpty) _emoji[file.path] = emoji;
      final next = [file.path, ...state];
      if (next.length > maxStickers) {
        for (final gone in next.sublist(maxStickers)) {
          _emoji.remove(gone);
          unawaited(File(gone).delete().catchError((_) => File(gone)));
        }
      }
      state = next.take(maxStickers).toList();
      await _persist();
    } catch (e) {
      debugPrint('StickerLibrary keep failed: $e');
    }
  }

  Future<void> forget(String path) async {
    final repaired = MediaPaths.repair(path);
    if (!state.contains(repaired)) return;
    state = [...state]..remove(repaired);
    _emoji.remove(repaired);
    unawaited(File(repaired).delete().catchError((_) => File(repaired)));
    await _persist();
  }

  Future<void> clear() async {
    for (final path in state) {
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    state = const <String>[];
    _emoji.clear();
    try {
      await _box?.delete(_key);
      await _box?.delete(_emojiKey);
    } catch (e) {
      debugPrint('StickerLibrary clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, [...state]);
      await _box?.put(_emojiKey, {..._emoji});
    } catch (e) {
      debugPrint('StickerLibrary persist failed: $e');
    }
  }
}

final stickerLibraryProvider =
    NotifierProvider<StickerLibrary, List<String>>(StickerLibrary.new);
