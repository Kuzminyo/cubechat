import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../models/pro_state.dart';
import 'entitlement_source.dart';

/// Whether this device may use Pro, and the two buttons that change it.
///
/// Nothing reads this yet, which is the point of the first step: the billing
/// is proved against the live stores before any feature depends on it.
class ProController extends Notifier<ProState> {
  static const _key = 'pro.source';

  StreamSubscription<ProState>? _sub;

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Resolves once the cached answer is in [state]. Anything that decides
  /// something on the strength of Pro has to wait on it; the same shape as
  /// `PrivacySettingsController.loaded`, and for the same reason.
  Future<void> get loaded => _loading ?? Future<void>.value();

  /// True once the store has spoken in this session, so a slow cache read
  /// cannot overwrite a fresher answer.
  bool _answered = false;

  @override
  ProState build() {
    final source = ref.watch(entitlementSourceProvider);
    _sub = source.changes.listen(
      (value) {
        // `remember` sets the state itself, so it is not set twice here.
        _answered = true;
        unawaited(remember(value));
      },
      // A dropped store connection is not evidence that somebody stopped
      // paying. The last known answer stands until the store says otherwise.
      onError: (Object e) => debugPrint('Pro entitlement stream failed: $e'),
    );
    ref.onDispose(() {
      unawaited(_sub?.cancel());
    });
    unawaited(_loading = _load());
    unawaited(source.start());
    return ProState.unknown;
  }

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      if (_answered) return;
      final name = box.get(_key) as String?;
      if (name == null) return;
      final cached = _sourceNamed(name);
      // An unknown name is a build that wrote a source this one does not have;
      // nothing is the safe reading, and the store is about to answer anyway.
      if (cached == null || cached == ProSource.none) return;
      state = ProState(source: cached, loaded: true);
    } catch (e) {
      debugPrint('Pro cache load failed: $e');
    }
  }

  static ProSource? _sourceNamed(String name) {
    for (final s in ProSource.values) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// Keep the store's answer for the next cold start.
  Future<void> remember(ProState value) async {
    state = value;
    try {
      // Waits for the box rather than dropping the write into a null one,
      // which is how an answer could hold for a session and be gone on the
      // next launch.
      await _loading;
      await _box?.put(_key, value.source.name);
    } catch (e) {
      debugPrint('Pro cache persist failed: $e');
    }
  }

  /// False when the store would not even start the purchase — see
  /// [EntitlementSource.buy]. The screen tells the user; nothing is logged as
  /// a fault.
  Future<bool> buy(ProProduct product) =>
      ref.read(entitlementSourceProvider).buy(product);

  Future<void> restore() => ref.read(entitlementSourceProvider).restore();
}

final proProvider =
    NotifierProvider<ProController, ProState>(ProController.new);

/// What the store charges, or an empty map until the products exist there.
final proPricesProvider = FutureProvider<Map<ProProduct, String>>(
  (ref) => ref.watch(entitlementSourceProvider).prices(),
);
