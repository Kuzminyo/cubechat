import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Whether a call may take the direct path between two phones.
///
/// **Off by default, and the reason is the whole of it.** A direct WebRTC path
/// hands each side the other's IP address, which is the network they are on
/// and roughly where they are standing. Somebody met over the mesh is not
/// necessarily somebody you want to have that. Off means every call is relayed
/// through our own TURN server: the person you call learns nothing about your
/// network, and the relay, which does see both addresses, carries sound it
/// cannot decrypt.
///
/// On trades that for a shorter path — lower latency, and no dependency on the
/// relay being up. It is a trade a person should make on purpose, which is why
/// it is a switch and not a heuristic.
///
/// It only ever widens what this phone offers. A phone with it off still
/// offers nothing but its relay candidate, so its own address stays hidden
/// even when calling somebody who has it on.
class CallRoutingController extends Notifier<bool> {
  static const _key = 'call.allow_direct';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Completes once the stored choice has been read. Before that the answer is
  /// the default, which is relay-only — so a caller that does not wait errs
  /// toward privacy, and a test that does not wait proves nothing.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  bool build() {
    unawaited(_loading = _load());
    return false;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      state = box.get(_key) as bool? ?? false;
    } catch (e) {
      debugPrint('Call routing load failed: $e');
    }
  }

  Future<void> set(bool allowDirect) async {
    state = allowDirect;
    try {
      await _box?.put(_key, allowDirect);
    } catch (e) {
      debugPrint('Call routing persist failed: $e');
    }
  }

  /// Back to relay-only — used by Emergency Wipe, which puts every setting
  /// back to what a fresh install would have.
  Future<void> reset() async {
    state = false;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Call routing reset failed: $e');
    }
  }
}

final callAllowsDirectProvider =
    NotifierProvider<CallRoutingController, bool>(CallRoutingController.new);
