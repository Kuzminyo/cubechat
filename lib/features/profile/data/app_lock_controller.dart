import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Whether this app asks for a code before it opens, and whether it is asking
/// right now.
///
/// Off by default and entirely optional. The app already refuses the network
/// what it does not need and refuses the system a screenshot of a photo; what
/// it could not refuse was a person holding the unlocked phone. That is a
/// different threat and not everybody has it, which is why this is a switch
/// rather than a wall everybody walks into.
///
/// The code is never stored. What is stored is a salted SHA-256 of it, in the
/// same encrypted box as the rest of the settings — so a stolen box yields a
/// hash a brute force still has to run, and the app itself cannot tell you
/// what your code was.
@immutable
class AppLockState {
  const AppLockState({
    this.enabled = false,
    this.locked = false,
    this.graceSeconds = 0,
    this.wrongAttempts = 0,
    this.penaltyUntil,
  });

  /// The switch.
  final bool enabled;

  /// Whether the code is being asked for right now. Always false when the
  /// switch is off.
  final bool locked;

  /// How long the app may be away before it asks again.
  ///
  /// Zero means every time. Anything else is the user saying they would rather
  /// not retype a code to answer a message thirty seconds after putting the
  /// phone down — which is a real preference and the reason a lock that always
  /// asks is a lock people turn off.
  final int graceSeconds;

  /// Wrong codes in a row. Reset by a right one.
  final int wrongAttempts;

  /// While this is in the future, the code is not accepted at all.
  ///
  /// Guessing a four-digit code takes ten thousand tries, which is minutes of
  /// tapping — unless something makes each try cost. This is that. It is
  /// stored, so closing the app is not a way out of the wait.
  final DateTime? penaltyUntil;

  /// How long the current wait has left, or zero.
  Duration get penaltyLeft {
    final until = penaltyUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get isPenalised => penaltyLeft > Duration.zero;

  AppLockState copyWith({
    bool? enabled,
    bool? locked,
    int? graceSeconds,
    int? wrongAttempts,
    DateTime? penaltyUntil,
    bool clearPenalty = false,
  }) =>
      AppLockState(
        enabled: enabled ?? this.enabled,
        locked: locked ?? this.locked,
        graceSeconds: graceSeconds ?? this.graceSeconds,
        wrongAttempts: wrongAttempts ?? this.wrongAttempts,
        penaltyUntil: clearPenalty ? null : (penaltyUntil ?? this.penaltyUntil),
      );

  @override
  bool operator ==(Object other) =>
      other is AppLockState &&
      other.enabled == enabled &&
      other.locked == locked &&
      other.graceSeconds == graceSeconds &&
      other.wrongAttempts == wrongAttempts &&
      other.penaltyUntil == penaltyUntil;

  @override
  int get hashCode =>
      Object.hash(enabled, locked, graceSeconds, wrongAttempts, penaltyUntil);
}

class AppLockController extends Notifier<AppLockState> {
  static const _hashKey = 'app.lock.hash';
  static const _saltKey = 'app.lock.salt';
  static const _graceKey = 'app.lock.grace';
  static const _penaltyKey = 'app.lock.penalty';
  static const _attemptsKey = 'app.lock.attempts';

  /// The waits a wrong code earns, after the third one in a row.
  ///
  /// Three is free because three is how often a person mistypes their own
  /// code. After that each try costs more than the last: half a minute, a
  /// minute, two, four, eight, and then a quarter of an hour for as long as
  /// somebody keeps going. Ten thousand codes at that rate is not an evening's
  /// work, and none of it inconveniences the owner, who is right on the fourth
  /// try at the latest.
  static const List<Duration> penalties = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 4),
    Duration(minutes: 8),
    Duration(minutes: 15),
  ];

  /// How long the app may be away before it asks again, as offered.
  static const List<int> graceChoices = [0, 30, 60, 300, 900, 3600];

  /// How long the app may be away before it asks again.
  ///
  /// Zero: every time the app is actually backgrounded, it asks.
  ///
  /// This was thirty seconds, on the reasoning that asking after every glance
  /// at a notification shade is how a lock becomes the thing people turn off.
  /// The reasoning was right and the number was answering it in the wrong
  /// place — a shade pull is `inactive`, and only `paused` and `hidden` reach
  /// [noteLeft] at all (see `app.dart`), so the glance was already excluded.
  /// What the grace actually did was make the lock look broken: minimise,
  /// come back in five seconds, nothing happens. Reported exactly that way.
  static const Duration grace = Duration.zero;

  Box<dynamic>? _box;
  DateTime? _leftAt;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  AppLockState build() {
    unawaited(_loading = _load());
    return const AppLockState();
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final grace = box.get(_graceKey) as int? ?? 0;
      final attempts = box.get(_attemptsKey) as int? ?? 0;
      final penaltyMs = box.get(_penaltyKey) as int?;
      // The wait outlives the process on purpose: closing the app must not be
      // a way out of it, which it would be if this lived only in memory.
      final penaltyUntil = penaltyMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(penaltyMs);
      final hash = box.get(_hashKey) as String?;
      final on = hash != null && hash.isNotEmpty;
      state = state.copyWith(
        // Locked on arrival when there is a code: a cold start is the case
        // this exists for.
        enabled: on,
        locked: on,
        graceSeconds: grace,
        wrongAttempts: attempts,
        penaltyUntil: penaltyUntil,
      );
    } catch (e) {
      debugPrint('AppLock load failed: $e');
    }
  }

  /// SHA-256 over salt and code.
  ///
  /// From `cryptography`, which this app already depends on for its X25519 and
  /// its HKDF, rather than from a second hashing package pulled in for one
  /// call — the pubspec says as much next to the curve it implements itself.
  /// Async because that library is, which is why every caller here is too.
  Future<String> _hash(String code, String salt) async {
    final digest = await Sha256().hash(utf8.encode('$salt|$code'));
    return base64Url.encode(digest.bytes);
  }

  String _mintSalt() {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
    return base64Url.encode(bytes);
  }

  /// Turn the lock on with [code]. Returns false if it could not be stored,
  /// in which case nothing is changed — a lock that half-exists is worse than
  /// none, because it would ask for a code no answer satisfies.
  Future<bool> enable(String code) async {
    if (code.length < 4) return false;
    // Wait for the box before writing to it.
    //
    // `_box` is filled by `_load`, which `build` starts and cannot await, and
    // `_box?.put(...)` on a null box is a silent no-op that still returned
    // true. So a code set in the first moments after launch reported success,
    // stored nothing, and was gone at the next start — the lock had been
    // turned on and never asked for anything again.
    await loaded;
    final box = _box;
    if (box == null) {
      debugPrint('AppLock: no settings box, refusing to half-enable');
      return false;
    }
    final salt = _mintSalt();
    try {
      await box.put(_saltKey, salt);
      await box.put(_hashKey, await _hash(code, salt));
    } catch (e) {
      debugPrint('AppLock persist failed: $e');
      return false;
    }
    state = const AppLockState(enabled: true, locked: false);
    return true;
  }

  /// Turn it off. Only with the current code — otherwise the lock is a
  /// suggestion anybody holding the phone can decline.
  Future<bool> disable(String code) async {
    if (!await verify(code)) return false;
    try {
      await _box?.delete(_hashKey);
      await _box?.delete(_saltKey);
    } catch (e) {
      debugPrint('AppLock clear failed: $e');
      return false;
    }
    state = const AppLockState();
    return true;
  }

  Future<bool> verify(String code) async {
    final hash = _box?.get(_hashKey) as String?;
    final salt = _box?.get(_saltKey) as String?;
    if (hash == null || salt == null) return false;
    return await _hash(code, salt) == hash;
  }

  /// The answer at the lock screen.
  /// The answer at the lock screen, with the cost of a wrong one.
  ///
  /// Refuses outright while a penalty is running — checking the code first
  /// would turn the wait into a rate limit somebody can simply wait out while
  /// still learning, one guess per window, whether each guess was right.
  Future<bool> unlock(String code) async {
    if (state.isPenalised) return false;
    if (!await verify(code)) {
      await _noteWrongCode();
      return false;
    }
    await _clearAttempts();
    state = state.copyWith(locked: false);
    return true;
  }

  Future<void> _noteWrongCode() async {
    final attempts = state.wrongAttempts + 1;
    // The first three are free: that is how often a person mistypes a code
    // they know.
    if (attempts <= 3) {
      state = state.copyWith(wrongAttempts: attempts);
      await _put(_attemptsKey, attempts);
      return;
    }
    final step = attempts - 4;
    final wait = penalties[step < penalties.length ? step : penalties.length - 1];
    final until = DateTime.now().add(wait);
    state = state.copyWith(wrongAttempts: attempts, penaltyUntil: until);
    await _put(_attemptsKey, attempts);
    await _put(_penaltyKey, until.millisecondsSinceEpoch);
  }

  Future<void> _clearAttempts() async {
    state = state.copyWith(wrongAttempts: 0, clearPenalty: true);
    await _put(_attemptsKey, 0);
    await _put(_penaltyKey, null);
  }

  /// How long the app may be away before it asks again.
  Future<void> setGraceSeconds(int seconds) async {
    state = state.copyWith(graceSeconds: seconds);
    await _put(_graceKey, seconds);
  }

  Future<void> _put(String key, Object? value) async {
    try {
      if (value == null) {
        await _box?.delete(key);
      } else {
        await _box?.put(key, value);
      }
    } catch (e) {
      debugPrint('AppLock persist $key failed: $e');
    }
  }

  /// Until when a backgrounding is one the app asked for.
  DateTime? _ourOwnExcursionUntil;

  /// The next trip out of the app is ours, not the user leaving.
  ///
  /// Picking a photo, choosing a file, sharing something, opening a link — all
  /// of them hand control to another app, and Android reports that exactly as
  /// it reports somebody pressing Home. With the delay set to "every time",
  /// coming back from the gallery therefore asked for the code, which is why
  /// setting an avatar wanted a password.
  ///
  /// A window rather than a flag that has to be cleared: whoever opens the
  /// picker cannot be relied on to be alive when it returns, and a flag left
  /// standing would be a lock quietly switched off. Generous enough to choose
  /// a photograph, and it only ever covers a trip this app started.
  void expectSystemUi() {
    _ourOwnExcursionUntil = DateTime.now().add(const Duration(minutes: 3));
  }

  /// The app went away. Remembered rather than acted on, because a glance at
  /// the shade is not leaving.
  void noteLeft() {
    if (!state.enabled) return;
    final excursion = _ourOwnExcursionUntil;
    if (excursion != null && DateTime.now().isBefore(excursion)) return;
    _leftAt = DateTime.now();
  }

  /// The app came back. Asks again only if it was away long enough.
  void noteReturned() {
    // Back from a picker of our own: the trip is over, so the next one has to
    // announce itself again. Cleared here rather than left to expire, so a
    // genuine departure a minute later still asks.
    _ourOwnExcursionUntil = null;
    if (!state.enabled || state.locked) return;
    final left = _leftAt;
    if (left == null) return;
    if (DateTime.now().difference(left) >=
        Duration(seconds: state.graceSeconds)) {
      state = state.copyWith(locked: true);
    }
  }

  /// Emergency Wipe: a fresh install has no lock.
  Future<void> reset() async {
    try {
      await _box?.delete(_hashKey);
      await _box?.delete(_saltKey);
    } catch (_) {}
    state = const AppLockState();
  }
}

final appLockControllerProvider =
    NotifierProvider<AppLockController, AppLockState>(AppLockController.new);
