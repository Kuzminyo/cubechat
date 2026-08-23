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
/// both feed the same scaler and neither is visible from in here. An override
/// answers exactly that: a phone tuned for something else can be brought back
/// to the size the screens were laid out at.
///
/// It used to be three fixed steps — small, normal, larger. Three steps is a
/// guess at which three, and the one somebody wants is reliably between two of
/// them; the range below is continuous and the ends are where the layout stops
/// coping, not where taste runs out.
@immutable
class UiScale {
  const UiScale._(this.factor);

  /// Follow the phone.
  static const UiScale system = UiScale._(null);

  /// An explicit multiplier, held inside what the screens survive.
  factory UiScale.of(double factor) =>
      UiScale._(factor.clamp(minFactor, maxFactor));

  /// The multiplier applied instead of the platform's, or null for "use
  /// theirs".
  final double? factor;

  /// Where the fixed-height capsules start clipping their own text at one end,
  /// and where the conversation stops fitting a sentence on a line at the
  /// other. Both were found by dragging, not chosen.
  static const double minFactor = 0.85;
  static const double maxFactor = 1.30;

  /// What the slider moves by. Fine enough that nobody is stuck between two
  /// sizes, coarse enough that the number under the thumb is readable.
  static const double step = 0.05;

  bool get followsSystem => factor == null;

  /// Read a stored value, in either shape it has ever had.
  ///
  /// Before this was continuous it was an enum stored by name, and phones in
  /// the field hold those names. They map to what they used to mean rather
  /// than being thrown away — somebody who chose "larger" gets larger, not a
  /// silent reset to the phone's own size.
  static UiScale fromStored(Object? stored) => switch (stored) {
        final num n => UiScale.of(n.toDouble()),
        'small' => UiScale.of(0.9),
        'normal' => UiScale.of(1.0),
        'large' => UiScale.of(1.15),
        _ => system,
      };

  /// What goes into the box: a number, or nothing at all for "follow".
  Object? get stored => factor;

  @override
  bool operator ==(Object other) =>
      other is UiScale && other.factor == factor;

  @override
  int get hashCode => factor.hashCode;

  @override
  String toString() => factor == null ? 'UiScale.system' : 'UiScale($factor)';
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
      final saved = UiScale.fromStored(box.get(_key));
      if (saved != state) state = saved;
    } catch (e) {
      debugPrint('UiScale load failed: $e');
    }
  }

  Future<void> select(UiScale scale) async {
    if (scale == state) return;
    state = scale;
    try {
      // Deleted rather than written for "follow the phone", so a fresh install
      // and a deliberate return to the default read identically.
      final value = scale.stored;
      if (value == null) {
        await _box?.delete(_key);
      } else {
        await _box?.put(_key, value);
      }
    } catch (e) {
      debugPrint('UiScale persist failed: $e');
    }
  }

  /// Emergency Wipe: back to following the phone.
  Future<void> reset() => select(UiScale.system);
}

final uiScaleControllerProvider =
    NotifierProvider<UiScaleController, UiScale>(UiScaleController.new);
