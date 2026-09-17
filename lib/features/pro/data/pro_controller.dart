import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/pro_state.dart';
import 'entitlement_source.dart';

/// Whether this device may use Pro, and the two buttons that change it.
///
/// Nothing reads this yet, which is the point of the first step: the billing
/// is proved against the live stores before any feature depends on it.
class ProController extends Notifier<ProState> {
  StreamSubscription<ProState>? _sub;

  @override
  ProState build() {
    final source = ref.watch(entitlementSourceProvider);
    _sub = source.changes.listen(
      (value) => state = value,
      // A dropped store connection is not evidence that somebody stopped
      // paying. The last known answer stands until the store says otherwise.
      onError: (Object e) => debugPrint('Pro entitlement stream failed: $e'),
    );
    ref.onDispose(() {
      unawaited(_sub?.cancel());
    });
    unawaited(source.start());
    return ProState.unknown;
  }

  Future<void> buy(ProProduct product) =>
      ref.read(entitlementSourceProvider).buy(product);

  Future<void> restore() => ref.read(entitlementSourceProvider).restore();
}

final proProvider =
    NotifierProvider<ProController, ProState>(ProController.new);
