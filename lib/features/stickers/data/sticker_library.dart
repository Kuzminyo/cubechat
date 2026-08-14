import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
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

  /// A cap, so a library nobody prunes cannot grow without limit. Oldest goes
  /// when the newest arrives — the same rule a recents row has always used.
  static const int maxStickers = 120;

  Box<dynamic>? _box;

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
      if (paths.isNotEmpty) state = paths;
    } catch (e) {
      debugPrint('StickerLibrary load failed: $e');
    }
  }

  bool has(String path) => state.contains(MediaPaths.repair(path));

  /// Keep a picture already on disk — one that arrived in a message.
  Future<void> keep(String sourcePath) async {
    final source = File(MediaPaths.repair(sourcePath));
    if (!await source.exists()) return;
    await _store(await source.readAsBytes());
  }

  /// Keep bytes that are not a file yet — one the user just picked or drew.
  Future<void> keepBytes(Uint8List bytes) => _store(bytes);

  Future<void> _store(Uint8List bytes) async {
    try {
      final dir = await mediaDirectory('cubechat-stickers');
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        's${DateTime.now().microsecondsSinceEpoch}.img',
      );
      await file.writeAsBytes(bytes);
      final next = [file.path, ...state];
      if (next.length > maxStickers) {
        for (final gone in next.sublist(maxStickers)) {
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
    unawaited(File(repaired).delete().catchError((_) => File(repaired)));
    await _persist();
  }

  Future<void> clear() async {
    for (final path in state) {
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    state = const <String>[];
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('StickerLibrary clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, [...state]);
    } catch (e) {
      debugPrint('StickerLibrary persist failed: $e');
    }
  }
}

final stickerLibraryProvider =
    NotifierProvider<StickerLibrary, List<String>>(StickerLibrary.new);
