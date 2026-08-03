import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// How large this app draws itself, independent of the rest of the phone.
///
/// [system] follows the device's own font-size setting, which is the right
/// default: someone who made every app bigger meant this one too. It is also
/// where the complaint comes from — the same build lands noticeably bigger on
/// one phone than another, because Android's Display size and iOS's Larger Text
/// both feed the same scaler and neither is visible from in here. The other
/// three are an override for exactly that: a phone tuned for something else can
/// be brought back to the size the screens were laid out at.
enum UiScale {
  system,
  small,
  normal,
  large;

  /// The multiplier applied to the platform's, or null for "use theirs".
  double? get factor => switch (this) {
        UiScale.system => null,
        UiScale.small => 0.9,
        UiScale.normal => 1.0,
        UiScale.large => 1.15,
      };

  static UiScale byName(String? name) =>
      UiScale.values.firstWhere((s) => s.name == name, orElse: () => system);
}

class UiScaleController extends Notifier<UiScale> {
  static const _key = 'app.ui_scale';

  Box<dynamic>? _box;

  @override
  UiScale build() {
    unawaited(_load());
    return UiScale.system;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final saved = UiScale.byName(box.get(_key) as String?);
      if (saved != state) state = saved;
    } catch (e) {
      debugPrint('UiScale load failed: $e');
    }
  }

  Future<void> select(UiScale scale) async {
    if (scale == state) return;
    state = scale;
    try {
      await _box?.put(_key, scale.name);
    } catch (e) {
      debugPrint('UiScale persist failed: $e');
    }
  }

  /// Emergency Wipe: back to following the phone.
  Future<void> reset() => select(UiScale.system);
}

final uiScaleControllerProvider =
    NotifierProvider<UiScaleController, UiScale>(UiScaleController.new);
