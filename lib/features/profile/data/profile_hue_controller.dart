import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// The colour your own profile is painted in, or null for the one your
/// identity gives you.
///
/// The twin of `ConversationSettings.profileHue`, which does the same for one
/// contact. Separate storage because it is not about a conversation: there is
/// no chat with yourself to hang it on, and filing it under a reserved chat id
/// would be a trick a reader has to know.
///
/// Local, like the per-contact one. Nothing about it goes on the wire — see
/// that field for why a colour somebody chose for *themselves* would be a much
/// larger feature than a colour you chose for them.
class ProfileHueController extends Notifier<double?> {
  static const _key = 'profile.hue';

  Box<dynamic>? _box;

  @override
  double? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final saved = (box.get(_key) as num?)?.toDouble();
      if (saved != state) state = saved;
    } catch (e) {
      debugPrint('ProfileHue load failed: $e');
    }
  }

  Future<void> select(double? hue) async {
    final next = hue == null ? null : hue % 360;
    if (next == state) return;
    state = next;
    try {
      // Deleted rather than written for "use my identity's colour", so a fresh
      // install and a deliberate reset read identically.
      if (next == null) {
        await _box?.delete(_key);
      } else {
        await _box?.put(_key, next);
      }
    } catch (e) {
      debugPrint('ProfileHue persist failed: $e');
    }
  }

  /// Emergency Wipe: back to the identity's own colour.
  Future<void> reset() => select(null);
}

final profileHueControllerProvider =
    NotifierProvider<ProfileHueController, double?>(ProfileHueController.new);
