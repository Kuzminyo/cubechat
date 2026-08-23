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
  const AppLockState({this.enabled = false, this.locked = false});

  /// The switch.
  final bool enabled;

  /// Whether the code is being asked for right now. Always false when the
  /// switch is off.
  final bool locked;

  AppLockState copyWith({bool? enabled, bool? locked}) => AppLockState(
        enabled: enabled ?? this.enabled,
        locked: locked ?? this.locked,
      );

  @override
  bool operator ==(Object other) =>
      other is AppLockState &&
      other.enabled == enabled &&
      other.locked == locked;

  @override
  int get hashCode => Object.hash(enabled, locked);
}

class AppLockController extends Notifier<AppLockState> {
  static const _hashKey = 'app.lock.hash';
  static const _saltKey = 'app.lock.salt';

  /// How long the app may be away before it asks again.
  ///
  /// Zero would ask after every glance at a notification shade, which is how a
  /// lock becomes the thing people turn off. Long enough to answer a call or
  /// check the time; short enough that a phone left on a table is not open.
  static const Duration grace = Duration(seconds: 30);

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
      final hash = box.get(_hashKey) as String?;
      if (hash != null && hash.isNotEmpty) {
        // Locked on arrival: a cold start is the case this exists for.
        state = const AppLockState(enabled: true, locked: true);
      }
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
    final salt = _mintSalt();
    try {
      await _box?.put(_saltKey, salt);
      await _box?.put(_hashKey, await _hash(code, salt));
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
  Future<bool> unlock(String code) async {
    if (!await verify(code)) return false;
    state = state.copyWith(locked: false);
    return true;
  }

  /// The app went away. Remembered rather than acted on, because a glance at
  /// the shade is not leaving.
  void noteLeft() {
    if (!state.enabled) return;
    _leftAt = DateTime.now();
  }

  /// The app came back. Asks again only if it was away long enough.
  void noteReturned() {
    if (!state.enabled || state.locked) return;
    final left = _leftAt;
    if (left == null) return;
    if (DateTime.now().difference(left) >= grace) {
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
