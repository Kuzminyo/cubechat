import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../features/peers/models/discovered_peer.dart';
import '../identity/nickname_controller.dart';
import '../util/platform_info.dart';
import 'ble_constants.dart';

/// Cubechat central-role scanner.
///
/// Maintains a live `Map<deviceId, DiscoveredPeer>` and re-emits a snapshot
/// every time the picture changes (new peer, RSSI moved, stale peer dropped).
///
/// Restarts scan windows automatically so the radio gets a periodic rest —
/// continuous BLE scanning is a battery liability and on some Androids the
/// stack throttles us if we never stop.
///
/// The cadence adapts: see [shouldScanActively].
class BleScanner {
  /// [isIOS] is injectable purely so the cadence can be tested off-device;
  /// production always takes the platform's own answer.
  BleScanner({bool? isIOS}) : _isIOS = isIOS ?? PlatformInfo.isIOS;

  /// Which platform's cycle shape to use — see [BleConstants.scanWindowFor].
  final bool _isIOS;

  /// Consulted at the start of every scan window to pick a cadence — active
  /// when the answer is true, idle when it's false. Null means always active.
  /// The durations each maps to are platform-dependent; see [BleConstants].
  ///
  /// A callback rather than a provider read so the scanner stays a plain
  /// object with no Riverpod dependency; [PeerDiscoveryController] wires it to
  /// "app is in the foreground, or we owe someone a delivery".
  bool Function()? shouldScanActively;

  /// Cadence chosen for the window currently running.
  bool _active = true;

  /// Window and gap of the cycle currently running, kept so [_gcPeriod] can
  /// pace itself against the cycle rather than a fixed interval.
  Duration _window = BleConstants.scanWindow;
  Duration _gap = BleConstants.scanGap;

  /// How long a peer may go unseen before [_gcStalePeers] drops it. Follows the
  /// running cadence: at the idle cadence a whole cycle is 30 s, so the active
  /// threshold would expire peers that never actually left.
  Duration get _staleAfter =>
      _active ? BleConstants.peerStaleAfter : BleConstants.peerStaleAfterIdle;

  /// How often stale peers are swept.
  ///
  /// While active someone may be watching the Nearby list, so a departed peer
  /// should disappear promptly. While idle nobody is looking, and a fixed 4 s
  /// sweep is seven isolate wakeups per idle cycle that can only ever find
  /// something once — so sweep once per cycle instead. A peer therefore
  /// lingers up to one extra cycle past [_staleAfter], which no one is awake
  /// to see.
  Duration get _gcPeriod =>
      _active ? const Duration(seconds: 4) : _window + _gap;

  final _peers = <String, DiscoveredPeer>{};
  final _controller = StreamController<List<DiscoveredPeer>>.broadcast();
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _cycleTimer;
  Timer? _gcTimer;

  /// Period [_gcTimer] is currently armed at, or null when it isn't running.
  Duration? _gcTimerPeriod;
  bool _running = false;

  Stream<List<DiscoveredPeer>> get peers => _controller.stream;
  Stream<BluetoothAdapterState> get adapterState => FlutterBluePlus.adapterState;

  Future<bool> get isSupported async => FlutterBluePlus.isSupported;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      if (s != BluetoothAdapterState.on && _scanSub != null) {
        _stopScanWindow();
      } else if (s == BluetoothAdapterState.on && _running && _scanSub == null) {
        unawaited(_startScanWindow());
      }
    });

    // Armed here so the sweep runs even while the adapter is off and no window
    // ever opens; _startScanWindow re-arms it whenever the cadence changes.
    _restartGcTimer();

    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter == BluetoothAdapterState.on) {
      await _startScanWindow();
    }
  }

  /// Re-pick the cadence now rather than at the next window boundary.
  ///
  /// The cadence is chosen when a window opens, so a change of circumstances
  /// mid-window — the user bringing the app back to the foreground, or a
  /// message queued for a peer who's offline — would otherwise not take effect
  /// for up to a full idle cycle. That is 30 s of sluggish discovery with the
  /// user watching the Nearby list, which is exactly what the idle cadence is
  /// supposed to avoid paying for.
  ///
  /// No-op unless the scanner is running and the cadence actually changed.
  Future<void> retune() async {
    if (!_running) return;
    final wanted = shouldScanActively?.call() ?? true;
    if (wanted == _active) return;
    await _stopScanWindow();
    if (_running) await _startScanWindow();
  }

  Future<void> stop() async {
    _running = false;
    _cycleTimer?.cancel();
    _gcTimer?.cancel();
    // Cleared, not just cancelled: _restartGcTimer treats a non-null timer as
    // already armed, so leaving the stale handle here would make a later
    // start() skip arming the sweep entirely.
    _gcTimer = null;
    _gcTimerPeriod = null;
    await _adapterSub?.cancel();
    _adapterSub = null;
    await _stopScanWindow();
    _peers.clear();
    _emit();
  }

  /// Force a fresh scan window and wait until the peer advertising
  /// [advertisedName] is seen again, returning the address it is answering on
  /// *now*. Android rotates the BLE privacy address, and we only refresh our
  /// view of it once per scan window (with a battery-saving gap in between),
  /// so an id cached from an earlier window can point at an address the peer
  /// has already abandoned — connecting there just times out.
  ///
  /// Returns null when the scanner isn't running, the name is unknown, or the
  /// peer isn't observed within [timeout]; callers should then fall back to
  /// the address they already have.
  Future<String?> refreshPeerId(
    String advertisedName, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (!_running || advertisedName.isEmpty) return null;

    // Only a sighting from *after* this moment proves the address is current;
    // the map still holds the previous one until a new result overwrites it.
    final since = DateTime.now();
    await _stopScanWindow();
    unawaited(_startScanWindow());

    final completer = Completer<String?>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    final sub = _controller.stream.listen((snapshot) {
      for (final p in snapshot) {
        if (p.advertisedName == advertisedName && p.lastSeen.isAfter(since)) {
          if (!completer.isCompleted) completer.complete(p.id);
          return;
        }
      }
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  Future<void> _startScanWindow() async {
    if (!_running) return;
    // Re-decided per window, so a resume (or a message queued for an offline
    // peer) tightens the cadence from the next window on.
    _active = shouldScanActively?.call() ?? true;
    _window = BleConstants.scanWindowFor(active: _active, isIOS: _isIOS);
    _gap = BleConstants.scanGapFor(active: _active, isIOS: _isIOS);
    // The sweep is paced off the cycle, so it has to be re-armed whenever the
    // cadence changes underneath it.
    _restartGcTimer();
    final window = _window;
    final gap = _gap;
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(BleConstants.serviceUuid)],
        timeout: window,
        // lowPower lengthens the radio's own duty cycle *within* the window,
        // on top of the longer gap between windows.
        androidScanMode:
            _active ? AndroidScanMode.balanced : AndroidScanMode.lowPower,
      );
    } catch (e, st) {
      debugPrint('BleScanner.startScan failed: $e\n$st');
    }

    _scanSub = FlutterBluePlus.scanResults.listen(_onResults);

    // After the window closes, rest then cycle again.
    _cycleTimer = Timer(window + gap, () async {
      await _stopScanWindow();
      if (_running) unawaited(_startScanWindow());
    });
  }

  Future<void> _stopScanWindow() async {
    _cycleTimer?.cancel();
    _cycleTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {
      // ignore — scan may have already been stopped by the platform.
    }
  }

  void _onResults(List<ScanResult> results) {
    var changed = false;
    final now = DateTime.now();
    for (final r in results) {
      final mac = r.device.remoteId.str;
      final advName = r.advertisementData.advName;
      final advertisedName = _resolveName(r);
      // Dedup key: Android rotates the BLE MAC for privacy, so the SAME
      // phone shows up under many addresses. The advertised name (our
      // nickname, made unique per identity for the default case) is stable
      // across rotation, so we key on it and keep the freshest MAC for
      // connecting. Unnamed advertisers fall back to the MAC.
      final key = advName.isNotEmpty ? 'n:$advName' : 'm:$mac';
      final existing = _peers[key];
      if (existing == null) {
        _peers[key] = DiscoveredPeer(
          id: mac,
          advertisedName: advertisedName,
          rssi: r.rssi,
          lastSeen: now,
        );
        changed = true;
        continue;
      }
      final rssiMoved = (existing.rssi - r.rssi).abs() >= 4;
      final macChanged = existing.id != mac;
      // Rebuild rather than copyWith so we can adopt the freshest MAC into
      // `id` (copyWith keeps id fixed).
      _peers[key] = DiscoveredPeer(
        id: mac,
        advertisedName: advertisedName,
        rssi: r.rssi,
        lastSeen: now,
        pubkeyFingerprint: existing.pubkeyFingerprint,
        isConnected: existing.isConnected,
      );
      if (rssiMoved || macChanged ||
          existing.advertisedName != advertisedName) {
        changed = true;
      }
    }
    if (changed) _emit();
  }

  String _resolveName(ScanResult r) {
    final adv = r.advertisementData.advName;
    if (adv.isNotEmpty) return adv;
    // Never fall back to platformName / the MAC: platformName is the OS
    // Bluetooth name (e.g. "Galaxy S24+"), which leaks the real device on what
    // is meant to be an anonymous mesh. A cubechat peer always advertises a
    // name; if it didn't reach us this window, show the anonymous default
    // until the handshake fills in their real one.
    return NicknameController.defaultNickname;
  }

  /// (Re-)arm the stale sweep at the period the running cadence calls for.
  /// No-op if it is already running at that period, so the common case — a
  /// window opening at an unchanged cadence — doesn't reset the phase and
  /// starve the sweep.
  void _restartGcTimer() {
    final period = _gcPeriod;
    if (_gcTimer != null && period == _gcTimerPeriod) return;
    _gcTimer?.cancel();
    _gcTimerPeriod = period;
    _gcTimer = Timer.periodic(period, (_) => _gcStalePeers());
  }

  void _gcStalePeers() {
    final now = DateTime.now();
    final stale = _peers.entries
        .where((e) =>
            !e.value.isConnected &&
            now.difference(e.value.lastSeen) > _staleAfter)
        .map((e) => e.key)
        .toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      _peers.remove(id);
    }
    _emit();
  }

  void _emit() {
    final snapshot = _peers.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    _controller.add(snapshot);
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
