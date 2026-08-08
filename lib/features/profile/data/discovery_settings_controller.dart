import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Whether this device announces itself to people it has never met.
///
/// The mesh's announcement is what makes proximity discovery work: a signed
/// bundle carrying your static X25519 key, your prekey, your Nostr address and
/// your nickname, broadcast to every link and relayed onward with a full hop
/// budget. That is exactly the right shape for "walk into a room and find each
/// other" — and exactly wrong if you did not want the room to know you are
/// there, because it hands every listener a permanent identifier plus a name.
///
/// It also undercuts rotating routing ids: the ids are derived from the static
/// key, so anyone who catches one cleartext announcement can recompute them
/// forever. Rotation is only worth something if the key stops being public.
///
/// Turning this off switches announcements from a cleartext broadcast to a
/// sealed, per-recipient introduction — the same bundle, encrypted to each
/// contact we already have. Strangers see an opaque frame addressed to an id
/// that means nothing to them.
///
/// **On by default.** Meeting someone new by standing next to them is the
/// premise of the app; silently disabling it would break the Peers screen for
/// everyone in exchange for a privacy property most users did not ask for.
@immutable
class DiscoverySettings {
  const DiscoverySettings({
    required this.discoverable,
    this.meshEnabled = true,
  });

  /// True: broadcast the announcement in the clear, as the mesh always has.
  /// False: introduce ourselves only to peers already in the roster, sealed.
  final bool discoverable;

  /// Whether the Bluetooth radio is used at all.
  ///
  /// Distinct from [discoverable], which is about what we *say* — with it off
  /// the radio still scans and still advertises, just without announcing us to
  /// strangers. This is the switch for the radio itself: off means no scanning
  /// and no advertising, so the phone stops spending power on the mesh
  /// entirely and the app is reachable only over the internet relay.
  ///
  /// Kept separate rather than folded into the background-mode toggle, because
  /// that one answers "may the app run when I am not looking at it" and this
  /// one answers "may it use Bluetooth at all" — a phone on wifi all day wants
  /// the second off and the first on.
  final bool meshEnabled;

  static const initial =
      DiscoverySettings(discoverable: true, meshEnabled: true);

  DiscoverySettings copyWith({bool? discoverable, bool? meshEnabled}) =>
      DiscoverySettings(
        discoverable: discoverable ?? this.discoverable,
        meshEnabled: meshEnabled ?? this.meshEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is DiscoverySettings &&
      other.discoverable == discoverable &&
      other.meshEnabled == meshEnabled;

  @override
  int get hashCode => Object.hash(discoverable, meshEnabled);
}

class DiscoverySettingsController extends Notifier<DiscoverySettings> {
  static const _key = 'discovery.discoverable';
  static const _meshKey = 'discovery.mesh_enabled';

  Box<dynamic>? _box;

  @override
  DiscoverySettings build() {
    unawaited(_load());
    return DiscoverySettings.initial;
  }

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      state = DiscoverySettings(
        discoverable: box.get(_key) as bool? ?? true,
        // Absent in history written before the switch existed, and the mesh is
        // the app — so "we do not know" reads as on.
        meshEnabled: box.get(_meshKey) as bool? ?? true,
      );
    } catch (e) {
      debugPrint('DiscoverySettings load failed: $e');
    }
  }

  Future<void> setMeshEnabled(bool value) async {
    state = state.copyWith(meshEnabled: value);
    try {
      await _box?.put(_meshKey, value);
    } catch (e) {
      debugPrint('DiscoverySettings persist failed: $e');
    }
  }

  Future<void> setDiscoverable(bool value) async {
    state = state.copyWith(discoverable: value);
    try {
      await _box?.put(_key, value);
    } catch (e) {
      debugPrint('DiscoverySettings persist failed: $e');
    }
  }

  /// Back to the default — used by Emergency Wipe, which restores every
  /// setting to what a fresh install would have.
  Future<void> reset() async {
    state = DiscoverySettings.initial;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('DiscoverySettings reset failed: $e');
    }
  }
}

final discoverySettingsProvider =
    NotifierProvider<DiscoverySettingsController, DiscoverySettings>(
  DiscoverySettingsController.new,
);
