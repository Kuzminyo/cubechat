import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/notifications/notification_service.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Hours in which the phone stays quiet.
///
/// Muting is per chat and answers "not this person". This answers "not now",
/// which is the other half people reach for and the one a mesh app needs more
/// than most: messages arrive whenever a peer wanders into range, and that is
/// as likely to be three in the morning as three in the afternoon.
///
/// It silences the *notification*, never the delivery. Everything still
/// arrives, is stored and is unread in the morning — the phone simply does not
/// light up. A feature that dropped messages to keep quiet would be a bug
/// wearing a setting's clothes.
@immutable
class QuietHours {
  const QuietHours({
    this.enabled = false,
    this.fromMinutes = 23 * 60,
    this.toMinutes = 8 * 60,
  });

  final bool enabled;

  /// Minutes past midnight, local time.
  final int fromMinutes;
  final int toMinutes;

  /// True when [at] falls inside the window.
  ///
  /// Handles the ordinary case of a window that crosses midnight, which is
  /// what almost every night is: 23:00 to 08:00 is "from is later than to",
  /// and a naive `from <= now && now < to` is quiet for exactly nobody.
  bool covers(DateTime at) {
    if (!enabled) return false;
    final minute = at.hour * 60 + at.minute;
    if (fromMinutes == toMinutes) return false; // a zero-length night
    return fromMinutes < toMinutes
        ? minute >= fromMinutes && minute < toMinutes
        : minute >= fromMinutes || minute < toMinutes;
  }

  QuietHours copyWith({bool? enabled, int? fromMinutes, int? toMinutes}) =>
      QuietHours(
        enabled: enabled ?? this.enabled,
        fromMinutes: fromMinutes ?? this.fromMinutes,
        toMinutes: toMinutes ?? this.toMinutes,
      );

  @override
  bool operator ==(Object other) =>
      other is QuietHours &&
      other.enabled == enabled &&
      other.fromMinutes == fromMinutes &&
      other.toMinutes == toMinutes;

  @override
  int get hashCode => Object.hash(enabled, fromMinutes, toMinutes);
}

class QuietHoursController extends Notifier<QuietHours> {
  static const _key = 'app.quiet_hours';

  Box<dynamic>? _box;

  @override
  QuietHours build() {
    unawaited(_load());
    // Read by the notification service, which has no Riverpod of its own — it
    // is called from the transport, off any widget tree.
    ref.listenSelf((_, next) => NotificationService.instance.quietNow = next.covers);
    return const QuietHours();
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        state = QuietHours(
          enabled: raw['enabled'] == true,
          fromMinutes: (raw['from'] as num?)?.toInt() ?? 23 * 60,
          toMinutes: (raw['to'] as num?)?.toInt() ?? 8 * 60,
        );
      }
    } catch (e) {
      debugPrint('QuietHours load failed: $e');
    }
  }

  Future<void> _put(QuietHours next) async {
    if (next == state) return;
    state = next;
    try {
      await _box?.put(_key, {
        'enabled': next.enabled,
        'from': next.fromMinutes,
        'to': next.toMinutes,
      });
    } catch (e) {
      debugPrint('QuietHours persist failed: $e');
    }
  }

  Future<void> setEnabled(bool on) => _put(state.copyWith(enabled: on));

  Future<void> setWindow({required int from, required int to}) =>
      _put(state.copyWith(fromMinutes: from, toMinutes: to));

  /// Emergency Wipe: back to the default night nobody chose.
  Future<void> reset() => _put(const QuietHours());
}

final quietHoursControllerProvider =
    NotifierProvider<QuietHoursController, QuietHours>(
  QuietHoursController.new,
);
