import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// When this device last wrote a backup, or null if it never has.
///
/// It exists for one reason: buying cubes is refused until a backup exists.
/// Reinstalling mints a new Nostr key, a balance is tied to that key, and a
/// balance whose key is gone is somebody's money gone — so the one place in
/// this app where a feature depends on a backup is the one where the cost of
/// not having it is measured in money rather than in inconvenience.
///
/// Only that a backup happened, and when. Not where it went, not what was in
/// it, and not the password — none of which this needs and all of which would
/// be worth stealing.
class BackupMadeController extends Notifier<DateTime?> {
  static const _key = 'backup.lastAt';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Resolves once the recorded time is in [state]. A screen that decides
  /// whether to offer a purchase has to wait on it, or it will offer a backup
  /// to somebody who made one last week.
  Future<void> get loaded => _loading ?? Future<void>.value();

  bool _changed = false;

  @override
  DateTime? build() {
    unawaited(_loading = _load());
    return null;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      if (_changed) return;
      final millis = box.get(_key) as int?;
      if (millis == null) return;
      state = DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (e) {
      debugPrint('Backup mark load failed: $e');
    }
  }

  /// Called when a backup has actually been written — not when one was
  /// started, and not when the sheet was opened.
  Future<void> mark(DateTime at) async {
    _changed = true;
    state = at;
    try {
      await _loading;
      await _box?.put(_key, at.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('Backup mark persist failed: $e');
    }
  }

  /// Emergency Wipe restores what a fresh install has, and a fresh install has
  /// never backed anything up.
  Future<void> reset() async {
    _changed = true;
    state = null;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Backup mark reset failed: $e');
    }
  }
}

final backupMadeProvider =
    NotifierProvider<BackupMadeController, DateTime?>(BackupMadeController.new);
