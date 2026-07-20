import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/ble_permissions.dart';
import '../../../core/ble/ble_scanner.dart';
import '../../../core/crypto/identity_service.dart';
import '../../../core/identity/anon_name.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/app_lifecycle.dart';
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

final blePermissionsProvider =
    Provider<BlePermissions>((_) => const BlePermissions());

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
  bool _nicknameWatched = false;

  /// Tail of the serialized advertise transitions — see [_serializeAdvertise].
  Future<void>? _advertiseChain;

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
    // Scan hard only when it buys something: while the user is in the app
    // (watching Nearby, or one tap from it), or while we're still chasing a
    // handover we only just failed to make. A backgrounded app with nothing
    // fresh to deliver drops to the idle cadence — see BleConstants.
    //
    // Deliberately hasFreshPendingDelivery, not hasPendingDelivery: the latter
    // stays true for the buffer's full one-hour TTL, so one undeliverable
    // message used to hold the radio at the active cadence for an hour.
    scanner.shouldScanActively = () =>
        AppLifecycle.instance.isForeground ||
        ref.read(messagingServiceProvider).hasFreshPendingDelivery;

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

  /// Ask the scanner to re-pick its scan cadence immediately — called when the
  /// app returns to the foreground, so discovery doesn't stay at the idle
  /// cadence for the remainder of a window the user is now watching.
  Future<void> retuneScan() => ref.read(bleScannerProvider).retune();

  Future<void> _bootPeripheral() async {
    // Wired before the first start, not after: a start that fails still needs
    // to pick up a later rename.
    _watchNickname();
    await _serializeAdvertise(() async {
      final peripheral = ref.read(peripheralControllerProvider.notifier);
      await peripheral.start(peerName: await _advertiseName());
    }, what: 'peripheral boot');
  }

  /// Re-advertise under the new name when the user renames themselves.
  /// The advertised name is baked into the GATT service at start(), so without
  /// this a rename only reached peers through mesh announcements — their Nearby
  /// list kept showing the old name until the app was restarted.
  void _watchNickname() {
    if (_nicknameWatched) return;
    _nicknameWatched = true;
    ref.listen<String>(nicknameControllerProvider, (prev, next) {
      if (prev == next) return;
      unawaited(_readvertise());
    });
  }

  Future<void> _readvertise() => _serializeAdvertise(() async {
        final peripheral = ref.read(peripheralControllerProvider.notifier);
        final name = await _advertiseName();
        // Advertising has to go down and back up for the name to change; the
        // native side reads it once at start.
        await peripheral.stop();
        await peripheral.start(peerName: name);
      }, what: 're-advertise after rename');

  /// Run advertise transitions one at a time.
  ///
  /// Each is a stop/start pair, and PeripheralController drops a start that
  /// arrives while another is in flight. Two renames in quick succession could
  /// therefore interleave into stop → stop → start(dropped) and leave the radio
  /// silent. Chaining them keeps the last rename the one that wins.
  Future<void> _serializeAdvertise(
    Future<void> Function() action, {
    required String what,
  }) {
    final next = (_advertiseChain ?? Future<void>.value()).then((_) async {
      try {
        await action();
      } catch (e, st) {
        debugPrint('$what failed: $e\n$st');
      }
    });
    _advertiseChain = next;
    return next;
  }

  /// Advertise the user's chosen nickname so other phones see something
  /// meaningful in their Nearby list instead of 'Android' / 'iPhone'.
  ///
  /// The advertised name is also the scanner's dedup key (it survives
  /// Android BLE MAC rotation, unlike the address). So the default name
  /// gets a short, stable per-identity suffix — otherwise two phones that
  /// never set a nickname would both advertise "Android" and the scanner
  /// would collapse them into a single Nearby entry.
  Future<String> _advertiseName() async {
    // The stored nickname loads asynchronously and the provider reads back the
    // default until it lands. Advertising is a once-per-start decision, so
    // reading it early pinned us to "Anonymous <tag>" for the whole session.
    await ref.read(nicknameControllerProvider.notifier).loaded;
    final nickname = ref.read(nicknameControllerProvider);
    if (nickname != NicknameController.defaultNickname) return nickname;
    // Default identity: advertise 'Anonymous <tag>' — anonymous by design,
    // and NOT 'Android'/'iPhone' or the OS device name. The tag matches
    // what a peer's Chats entry derives from our pubkey, so Nearby and
    // Chats agree on the label.
    const base = NicknameController.defaultNickname;
    final suffix = await _identitySuffix();
    return suffix == null ? base : '$base $suffix';
  }

  /// 4 hex chars derived from our identity pubkey — the [anonTag]. Stable
  /// across restarts and identical to what a peer computes from our pubkey
  /// hex, so the anonymous label matches between our advertisement and their
  /// Chats list.
  Future<String?> _identitySuffix() async {
    try {
      final id = await ref.read(identityProvider.future);
      final hex =
          id.publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return anonTag(hex);
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

  Future<void> openSettings() =>
      ref.read(blePermissionsProvider).openSettings();

  Future<void> stop() async {
    await ref.read(bleScannerProvider).stop();
    _disposeSubscriptions();
    state = state.copyWith(status: PeerDiscoveryStatus.idle, peers: const []);
  }

  /// Take the radio fully down — scanning *and* advertising.
  ///
  /// [stop] only parks the scanner, which is the right thing when the Peers
  /// screen goes away but the app is still meant to be reachable. This is the
  /// stronger version, for when the user has asked us not to run in the
  /// background at all.
  ///
  /// Only iOS needs it. On Android "keep running in the background" is a
  /// foreground service: switching it off lets the OS suspend us, and the radio
  /// stops as a consequence. iOS has no equivalent — UIBackgroundModes
  /// (bluetooth-central/peripheral) keeps the process alive indefinitely
  /// whether the user wants it or not, so the preference has to be enforced
  /// here in Dart or it means nothing at all.
  ///
  /// Advertising goes through the same chain as every other transition so a
  /// suspend can't interleave with an in-flight re-advertise and leave the
  /// radio in a state neither of them intended.
  Future<void> suspend() async {
    await ref.read(bleScannerProvider).stop();
    await _serializeAdvertise(
      () => ref.read(peripheralControllerProvider.notifier).stop(),
      what: 'suspend advertising',
    );
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
