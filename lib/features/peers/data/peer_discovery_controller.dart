import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/ble_permissions.dart';
import '../../../core/ble/ble_scanner.dart';
import '../../../core/crypto/identity_service.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/platform_info.dart';
import '../models/discovered_peer.dart';
import 'peripheral_controller.dart';

/// All the things that can be wrong with BLE on the current device.
enum PeerDiscoveryStatus {
  /// Initial state before we've checked anything.
  idle,

  /// Platform doesn't ship BLE (e.g. iOS Simulator, Windows in dev).
  unsupported,

  /// User has not yet been asked for permission.
  permissionsUnknown,

  /// User actively denied permissions.
  permissionsDenied,

  /// User permanently denied — only Settings can unstick.
  permissionsPermanentlyDenied,

  /// Bluetooth radio is off / unauthorized / unavailable.
  adapterOff,

  /// Actively scanning.
  scanning,
}

@immutable
class PeerDiscoveryState {
  const PeerDiscoveryState({
    required this.status,
    required this.peers,
  });

  final PeerDiscoveryStatus status;
  final List<DiscoveredPeer> peers;

  PeerDiscoveryState copyWith({
    PeerDiscoveryStatus? status,
    List<DiscoveredPeer>? peers,
  }) {
    return PeerDiscoveryState(
      status: status ?? this.status,
      peers: peers ?? this.peers,
    );
  }

  static const initial = PeerDiscoveryState(
    status: PeerDiscoveryStatus.idle,
    peers: [],
  );
}

final blePermissionsProvider = Provider<BlePermissions>((_) => const BlePermissions());

final bleScannerProvider = Provider<BleScanner>((ref) {
  final scanner = BleScanner();
  ref.onDispose(() => unawaited(scanner.dispose()));
  return scanner;
});

final peerDiscoveryControllerProvider =
    NotifierProvider<PeerDiscoveryController, PeerDiscoveryState>(
  PeerDiscoveryController.new,
);

class PeerDiscoveryController extends Notifier<PeerDiscoveryState> {
  StreamSubscription<List<DiscoveredPeer>>? _peerSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  @override
  PeerDiscoveryState build() {
    ref.onDispose(_disposeSubscriptions);
    return PeerDiscoveryState.initial;
  }

  /// Top-level entry point. Idempotent — safe to call from initState every time
  /// the Peers screen is built.
  Future<void> start() async {
    // Eagerly construct the messaging service so its peripheral-event
    // subscription is up before we start advertising.
    ref.read(messagingServiceProvider);

    final scanner = ref.read(bleScannerProvider);

    // Web/desktop don't have meaningful BLE peripheral support yet, and
    // central support varies. Bail with a clear status.
    if (!PlatformInfo.isMobile) {
      state = state.copyWith(status: PeerDiscoveryStatus.unsupported);
      return;
    }

    if (!await scanner.isSupported) {
      state = state.copyWith(status: PeerDiscoveryStatus.unsupported);
      return;
    }

    final perms = ref.read(blePermissionsProvider);
    final current = await perms.check();
    if (current != BlePermissionState.granted &&
        current != BlePermissionState.notApplicable) {
      state = state.copyWith(status: PeerDiscoveryStatus.permissionsUnknown);
      return;
    }

    await _wireStreams();
    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      state = state.copyWith(status: PeerDiscoveryStatus.adapterOff);
      // Still start the scanner — it parks itself until the adapter comes up.
    } else {
      state = state.copyWith(status: PeerDiscoveryStatus.scanning);
    }

    if (!scanner.isRunning) {
      await scanner.start();
    }

    // Bring up the peripheral side too so other devices can find us.
    // Pulled into a microtask so a failure here doesn't block the scanner UI.
    unawaited(_bootPeripheral());
  }

  Future<void> _bootPeripheral() async {
    try {
      final peripheral = ref.read(peripheralControllerProvider.notifier);
      // Advertise the user's chosen nickname so other phones see something
      // meaningful in their Nearby list instead of 'Android' / 'iPhone'.
      //
      // The advertised name is also the scanner's dedup key (it survives
      // Android BLE MAC rotation, unlike the address). So the default name
      // gets a short, stable per-identity suffix — otherwise two phones that
      // never set a nickname would both advertise "Android" and the scanner
      // would collapse them into a single Nearby entry.
      final nickname = ref.read(nicknameControllerProvider);
      String advertiseName;
      if (nickname != NicknameController.defaultNickname) {
        advertiseName = nickname;
      } else {
        final base = PlatformInfo.isIOS ? 'iPhone' : 'Android';
        final suffix = await _identitySuffix();
        advertiseName = suffix == null ? base : '$base $suffix';
      }
      await peripheral.start(peerName: advertiseName);
    } catch (e, st) {
      debugPrint('peripheral boot failed: $e\n$st');
    }
  }

  /// 4 hex chars derived from our identity pubkey — stable across restarts
  /// and unique per device, used to disambiguate default advertise names.
  Future<String?> _identitySuffix() async {
    try {
      final id = await ref.read(identityProvider.future);
      final digest = await Blake2s().hash(id.publicKey);
      final b = digest.bytes;
      return b[0].toRadixString(16).padLeft(2, '0') +
          b[1].toRadixString(16).padLeft(2, '0');
    } catch (_) {
      return null;
    }
  }

  Future<void> requestPermissions() async {
    final perms = ref.read(blePermissionsProvider);
    final result = await perms.request();
    switch (result) {
      case BlePermissionState.granted:
      case BlePermissionState.notApplicable:
        await start();
      case BlePermissionState.denied:
        state = state.copyWith(status: PeerDiscoveryStatus.permissionsDenied);
      case BlePermissionState.permanentlyDenied:
        state = state.copyWith(
          status: PeerDiscoveryStatus.permissionsPermanentlyDenied,
        );
    }
  }

  Future<void> openSettings() => ref.read(blePermissionsProvider).openSettings();

  Future<void> stop() async {
    await ref.read(bleScannerProvider).stop();
    _disposeSubscriptions();
    state = state.copyWith(status: PeerDiscoveryStatus.idle, peers: const []);
  }

  Future<void> _wireStreams() async {
    final scanner = ref.read(bleScannerProvider);
    await _peerSub?.cancel();
    _peerSub = scanner.peers.listen((peers) {
      state = state.copyWith(peers: peers);
      _maybeAutoConnect(peers);
    });
    await _adapterSub?.cancel();
    _adapterSub = scanner.adapterState.listen((s) {
      if (s == BluetoothAdapterState.on) {
        if (state.status == PeerDiscoveryStatus.adapterOff ||
            state.status == PeerDiscoveryStatus.idle) {
          state = state.copyWith(status: PeerDiscoveryStatus.scanning);
        }
      } else {
        state = state.copyWith(status: PeerDiscoveryStatus.adapterOff);
      }
    });
  }

  // ---- opportunistic auto-connect (store-and-forward delivery) ----

  /// Per-MAC cooldown so we don't hammer the same advertiser with connect
  /// attempts every scan tick.
  final Map<String, DateTime> _autoAttempts = {};
  static const _autoCooldown = Duration(seconds: 25);
  static const _maxAutoPerTick = 2;

  /// When we're holding messages for someone who's offline, auto-connect to
  /// any peer the scanner turns up — a handshake completes the link, which
  /// flushes the store-and-forward buffer (so a message sent while the
  /// recipient's Bluetooth was off is delivered the moment they switch it
  /// back on and we see them). Throttled and capped to keep churn/battery
  /// sane; connectAsInitiator already no-ops if we're mid-connect to that id.
  void _maybeAutoConnect(List<DiscoveredPeer> peers) {
    final messaging = ref.read(messagingServiceProvider);
    if (!messaging.hasPendingDelivery) return;

    final now = DateTime.now();
    _autoAttempts.removeWhere((_, t) => now.difference(t) > _autoCooldown);

    var started = 0;
    for (final peer in peers) {
      if (started >= _maxAutoPerTick) break;
      if (peer.isConnected) continue;
      final last = _autoAttempts[peer.id];
      if (last != null && now.difference(last) < _autoCooldown) continue;
      _autoAttempts[peer.id] = now;
      started++;
      unawaited(() async {
        try {
          await messaging.connectAsInitiator(
            BluetoothDevice.fromId(peer.id),
            displayName: peer.advertisedName,
          );
        } catch (_) {
          // transient — the cooldown will let us retry later
        }
      }());
    }
  }

  void _disposeSubscriptions() {
    _peerSub?.cancel();
    _adapterSub?.cancel();
    _peerSub = null;
    _adapterSub = null;
  }
}
