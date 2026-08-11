import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/background_mode_controller.dart';
import '../../../core/ble/background_service.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/shared_location.dart';
import '../../../core/util/location_service.dart';
import '../../../core/util/platform_info.dart';
import '../../profile/data/privacy_settings_controller.dart';
import 'map_friends_controller.dart';

/// Keeps our live position current for confirmed map friends — while the app
/// is open, and while it is not.
///
/// Two sources feed the same beacon. A 45-second timer takes one-shot fixes,
/// which is cheap and precise while the app is on screen. A position
/// subscription ([LocationService.watch]) covers everything after that: on iOS
/// it is the only thing that keeps the app alive once it leaves the screen at
/// all, and on Android it is what turns the process the mesh foreground
/// service is already holding open into a phone that still says where it is.
///
/// Both are armed only when there is a reason to be: map sharing on, and at
/// least one confirmed friend to receive it. Neither runs otherwise — this is
/// the most expensive thing the app can do to a battery, and it should cost
/// nothing at all for the people who have not asked for it.
class MapPresenceController extends Notifier<int> {
  static const _tick = Duration(seconds: 45);
  static const _ttl = Duration(minutes: 2);

  Timer? _timer;
  StreamSubscription<LocationFix>? _watch;
  bool _watchStarting = false;
  bool _sending = false;
  DateTime? _lastSentAt;
  String? _lastCell;

  @override
  int build() {
    _arm();
    ref.listen<Set<String>>(mapFriendsControllerProvider, (_, __) => _arm());
    ref.listen<PrivacySettings>(privacySettingsProvider, (before, after) {
      // Switching map sharing off has to *retract* the pin, not merely stop
      // refreshing it. Stopping leaves the last beacon standing on every
      // friend's map until its own two-minute TTL lapses — so the switch that
      // means "nobody sees where I am" would still show where you were, for two
      // minutes, which is the whole of what someone reaches for it to prevent.
      if ((before?.shareMapLocation ?? false) && !after.shareMapLocation) {
        unawaited(withdraw());
      }
      _arm();
    });
    ref.onDispose(() {
      _timer?.cancel();
      unawaited(_watch?.cancel());
    });
    return 0;
  }

  /// Tell every map friend to drop our pin, now.
  ///
  /// A flagged, already-expired beacon rather than a new payload type: the
  /// receiver reads the flag as "remove this person", so retraction costs no
  /// protocol surface, and an older build sees a position that expired before
  /// it arrived and lets the pin lapse as it always did.
  Future<void> withdraw() async {
    _lastCell = null;
    _lastSentAt = null;
    final peers = ref.read(mapFriendsControllerProvider).toList(growable: false);
    if (peers.isEmpty) return;
    final gone = SharedLocation(
      latitude: 0,
      longitude: 0,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      presence: true,
      retract: true,
    ).encode();
    final messaging = ref.read(messagingServiceProvider);
    for (final peerId in peers) {
      try {
        await messaging.sendText(peerId, gone, transient: true);
      } catch (e) {
        debugPrint('MapPresenceController withdraw failed for $peerId: $e');
      }
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (!_shouldShare) {
      unawaited(_stopWatching());
      return;
    }
    unawaited(_startWatching());
    _timer = Timer.periodic(_tick, (_) => unawaited(_sendUpdate()));
    unawaited(_sendUpdate(force: true));
  }

  bool get _shouldShare =>
      ref.read(privacySettingsProvider).shareMapLocation &&
      ref.read(mapFriendsControllerProvider).isNotEmpty;

  Future<void> _startWatching() async {
    if (_watch != null || _watchStarting) return;
    _watchStarting = true;
    try {
      const service = LocationService();
      if (!await service.ensureBackgroundPermission()) return;
      // Re-check: asking for permission can take a while, and "stop sharing"
      // is exactly the sort of thing somebody does while a system dialog is
      // in front of them.
      if (!_shouldShare) return;
      if (PlatformInfo.isAndroid && ref.read(backgroundModeProvider)) {
        // The mesh service usually starts at boot, i.e. before location was
        // ever granted — so it is running as a connectedDevice service only,
        // and this stream would be cut off the moment the app leaves the
        // screen. Starting it again re-promotes it with the `location` type
        // it can now claim. Idempotent; the service is already up.
        unawaited(BackgroundService.instance.start());
      }
      _watch = service.watch().listen(
        (fix) => unawaited(_publish(fix)),
        onError: (Object e) =>
            debugPrint('MapPresenceController location stream failed: $e'),
        cancelOnError: false,
      );
    } finally {
      _watchStarting = false;
    }
  }

  Future<void> _stopWatching() async {
    final watch = _watch;
    _watch = null;
    await watch?.cancel();
  }

  Future<void> pokeNow() => _sendUpdate(force: true);

  /// Take a fix and publish it. The timer's half of the job.
  Future<void> _sendUpdate({bool force = false}) async {
    if (_sending || !_shouldShare) return;
    final (fix, _) = await const LocationService().current();
    if (fix == null) return;
    await _publish(fix, force: force);
  }

  /// Hand one position to every map friend.
  ///
  /// The lifecycle check that used to sit at the top of this — send nothing
  /// unless the app is in the foreground — is gone deliberately. It made the
  /// pin mean "where they were when they last had the app open", which is not
  /// what anyone reads a live map for. What still gates the beacon is consent:
  /// the sharing switch, and having somebody to send it to.
  Future<void> _publish(LocationFix fix, {bool force = false}) async {
    if (_sending || !_shouldShare) return;
    final peers = ref.read(mapFriendsControllerProvider).toList(growable: false);
    if (peers.isEmpty) return;

    _sending = true;
    try {
      final now = DateTime.now();
      final cell =
          '${fix.latitude.toStringAsFixed(4)}:${fix.longitude.toStringAsFixed(4)}';
      if (!force &&
          _lastCell == cell &&
          _lastSentAt != null &&
          now.difference(_lastSentAt!) < const Duration(seconds: 35)) {
        return;
      }

      final share = SharedLocation(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyMetres: fix.accuracyMetres,
        expiresAt: now.add(_ttl),
        presence: true,
      ).encode();

      final messaging = ref.read(messagingServiceProvider);
      for (final peerId in peers) {
        try {
          await messaging.sendText(peerId, share, transient: true);
        } catch (e) {
          debugPrint('MapPresenceController send failed for $peerId: $e');
        }
      }
      _lastCell = cell;
      _lastSentAt = now;
    } finally {
      _sending = false;
    }
  }
}

final mapPresenceControllerProvider =
    NotifierProvider<MapPresenceController, int>(MapPresenceController.new);
