import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// The rules version the app currently asks everyone to accept.
///
/// Bumping this — never done lightly, and never as part of this task — puts
/// the gate back in front of every phone at its next launch, accepted version
/// or not: see [TermsController.build] and the `>=` check in `TermsGate`.
const int currentTermsVersion = 1;

/// Which version of the rules this phone has agreed to, `0` for none.
///
/// Same shape as [AirDropLaneController] next to it: a `Notifier<int>` backed
/// by one key in the encrypted settings box, with a `loaded` future for
/// callers that need to know the disk read has actually happened (the gate
/// does; a flash of the app before that read finishes is exactly the bug this
/// exists to avoid) and a `_touched` guard against the same load race that
/// controller's comment documents — `reset()` is what the emergency wipe
/// calls, on a provider nobody may have read yet, and `_load()` finishing
/// afterwards must not clobber that with whatever was still on disk.
class TermsController extends Notifier<int> {
  static const storageKey = 'moderation.termsAccepted';

  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _touched = false;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  int build() {
    unawaited(_loading = _load());
    return 0;
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      if (_touched) return;
      final raw = _box?.get(storageKey);
      if (raw is! int) return;
      state = raw;
    } catch (e) {
      debugPrint('TermsController load failed: $e');
    }
  }

  /// The one tap that gets you past the gate.
  Future<void> accept() async {
    _touched = true;
    state = currentTermsVersion;
    await loaded;
    await _box?.put(storageKey, currentTermsVersion);
  }

  /// Emergency wipe: a fresh install has not agreed to anything.
  Future<void> reset() async {
    _touched = true;
    state = 0;
    await loaded;
    await _box?.delete(storageKey);
  }
}

final termsControllerProvider =
    NotifierProvider<TermsController, int>(TermsController.new);
