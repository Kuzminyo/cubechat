import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/debug_log.dart';
import '../util/platform_info.dart';

/// What to do when the platform secure store throws on a read.
///
/// A read that *throws* is not a read that found nothing, and until
/// 2026-10-14 both callers treated it as one: [IdentityService] answered with
/// `deleteAll()` and a fresh keypair, [HiveCipherProvider] with a fresh history
/// key. A fresh history key is a wipe on its own — Hive opens a box under the
/// wrong key without complaint, finds the first frame's checksum wrong, and its
/// crash recovery truncates the file to zero (`storage_backend_vm.dart`,
/// `crashRecovery` is on by default). A fresh identity is what an uninstall
/// costs: every conversation dead on both ends.
///
/// And the likely cause is not a corrupt store. The iOS entries are
/// `first_unlock`, so every read before the first unlock after a reboot fails
/// by design, and a VoIP push or a Bluetooth restore is exactly what launches
/// us then. Android's EncryptedSharedPreferences has transient failures too.
/// The permanent one — `BAD_DECRYPT` after an OS update replaced the master
/// key — is real, and it is the only case the old reset was right for.
///
/// So a failed read now waits and asks again, and the store is only reset once
/// it has failed without a single success for longer than a locked phone could
/// explain: [_androidWindow] on Android, [_appleWindow] on iOS, where a phone
/// can sit locked all night after a reboot. The window is wall-clock and kept
/// across launches, so a broken store still resets — on its first read after
/// the window — whether or not the app stayed open the whole time.
class SecureReadPolicy {
  SecureReadPolicy({
    Future<SharedPreferences> Function()? prefs,
    DateTime Function()? now,
    Duration? window,
    Duration Function(int attempt)? delay,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now,
        _window = window,
        _delay = delay ?? _backoff;

  static const _firstFailureKey = 'cubechat.secureRead.firstFailureAt';

  /// Fewer than this many failed reads never resets, however old the first
  /// one: a single failure a day ago followed by one today is two launches
  /// that each met a locked phone, not a broken store.
  static const minAttempts = 3;

  static const _androidWindow = Duration(minutes: 5);
  static const _appleWindow = Duration(hours: 24);

  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _now;
  final Duration? _window;
  final Duration Function(int attempt) _delay;

  Duration get window =>
      _window ?? (PlatformInfo.isIOS ? _appleWindow : _androidWindow);

  /// How long to wait before read number [attempt] + 1.
  Duration delayAfter(int attempt) => _delay(attempt);

  /// 1 s, 2 s, 4 s … capped at 30 s: quick enough that a transient failure
  /// costs a second, slow enough that a phone locked overnight is not woken
  /// every frame to ask.
  static Duration _backoff(int attempt) {
    final seconds = 1 << (attempt - 1).clamp(0, 5);
    return Duration(seconds: seconds > 30 ? 30 : seconds);
  }

  /// Called after read number [attempts] threw [error]. True means the store
  /// is broken rather than locked, and the caller may reset it.
  Future<bool> shouldReset(
    String what,
    Object error, {
    required int attempts,
  }) async {
    final now = _now();
    DateTime? first;
    try {
      final prefs = await _prefs();
      final stored = prefs.getInt(_firstFailureKey);
      if (stored == null) {
        await prefs.setInt(_firstFailureKey, now.millisecondsSinceEpoch);
      } else {
        first = DateTime.fromMillisecondsSinceEpoch(stored);
      }
    } catch (e) {
      // Plain preferences unreadable too — on iOS before the first unlock
      // they are. Never a reason to reset: no evidence is no evidence.
      debugPrint('SecureReadPolicy: no failure ledger ($e)');
    }
    final failingFor = first == null ? Duration.zero : now.difference(first);
    final reset = attempts >= minAttempts && failingFor >= window;
    if (attempts == 1 || attempts % 10 == 0 || reset) {
      DebugLog.instance.log(
        'STORE',
        '$what: secure read failed (attempt $attempts, failing for '
            '${failingFor.inMinutes} min): $error'
            '${reset ? ' — resetting' : ' — keeping the key, retrying'}',
      );
    }
    return reset;
  }

  /// Called after a read that did not throw. Clears the ledger, so the window
  /// only ever measures failures with no success between them.
  Future<void> succeeded() async {
    try {
      final prefs = await _prefs();
      if (prefs.containsKey(_firstFailureKey)) {
        await prefs.remove(_firstFailureKey);
      }
    } catch (_) {
      // Next success clears it.
    }
  }
}

/// Shared by [IdentityService] and [HiveCipherProvider]: one store, one ledger.
final secureReadPolicy = SecureReadPolicy();
