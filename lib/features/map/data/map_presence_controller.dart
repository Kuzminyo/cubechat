import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/background_mode_controller.dart';
import '../../../core/ble/background_service.dart';
import '../../../core/notifications/ios_significant_location.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/shared_location.dart';
import '../../../core/util/location_service.dart';
import '../../../core/util/platform_info.dart';
import '../../profile/data/privacy_settings_controller.dart';
import 'map_friends_controller.dart';
import '../../../core/util/debug_log.dart';

/// A position, and the moment it was taken.
///
/// Shared so that everything wanting to know where this phone is reads the
/// same answer instead of asking the radio for its own. See
/// [lastLocationFixProvider].
@immutable
class StampedLocationFix {
  const StampedLocationFix(this.fix, this.at);

  final LocationFix fix;
  final DateTime at;

  /// How old a fix may be and still stand in for a new one. Long enough to
  /// cover the gap between the beacon's timer and the map's own refresh;
  /// short enough that a walking person's pin is still where they are.
  static const stillGood = Duration(seconds: 60);

  LocationFix? get fresh =>
      DateTime.now().difference(at) <= stillGood ? fix : null;
}

/// The last position the app obtained, from whichever consumer obtained it.
///
/// Deliberately a plain state provider rather than a getter on the presence
/// controller: reading it must not bring that controller to life, because the
/// map screen reads it on every refresh and building the controller starts a
/// location subscription.
final lastLocationFixProvider = StateProvider<StampedLocationFix?>((_) => null);

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

  /// How long the same position may go unrepeated.
  ///
  /// A beacon carries [_ttl], so a pin that stops being refreshed disappears
  /// after two minutes; re-sending is only ever about staying inside that. The
  /// figure was 35 s against a 45 s tick, which meant a phone lying still on a
  /// desk re-published an identical position on *every* tick — a full X3DH
  /// derivation and Schnorr signature per map friend, every 45 seconds,
  /// carrying no news whatsoever.
  ///
  /// A shared log showed exactly that: sends to four peers at 16:47:57,
  /// 16:48:42, 16:49:27, 16:50:10, 16:50:57 — the tick, unbroken, from a
  /// stationary phone. It is also the shape of "CPU иногда 3 а иногда 16": the
  /// bursts are these fan-outs, and the gaps between them are idle.
  ///
  /// Seventy seconds skips every other tick, so an unmoved position now goes
  /// out about every 90 s and still has 30 s of margin before the pin it is
  /// refreshing would have expired. A phone that is actually *moving* is
  /// unaffected — the cell changes, and a changed cell was never throttled.
  static const _repeatSamePlaceAfter = Duration(seconds: 70);

  Timer? _timer;
  StreamSubscription<LocationFix>? _watch;
  bool _watchStarting = false;
  bool _sending = false;

  /// Consecutive beacon rounds that reached nobody at all.
  ///
  /// The GPS subscription used to be gated on `_shouldShare`, which asks only
  /// whether the switch is on and the map-friend list is non-empty. Neither of
  /// those means anybody is *receiving* anything, and the difference is not
  /// theoretical: a friend entry whose pubkey no longer resolves fails every
  /// single send — `cannot send: no recipient pubkey for …` in the log — while
  /// the list stays non-empty and the position stream runs on.
  ///
  /// An Android battery report made the cost concrete: 1 h 47 min of GPS
  /// against 7 min of CPU over the same 6½ hours, almost all of it with the
  /// app in the background. Three rounds of talking to nobody now parks the
  /// radio; a single successful send starts it again.
  int _deadRounds = 0;

  /// About two minutes at [_tick]. Long enough to ride out a transport that is
  /// still coming up after a launch, which is the ordinary reason a beacon
  /// fails, and short enough that a dead friend list does not cost an evening.
  static const _deadRoundsBeforeIdle = 3;

  bool get _beaconIsLanding => _deadRounds < _deadRoundsBeforeIdle;
  DateTime? _lastSentAt;
  /// Where the last beacon that actually went out said we were.
  ///
  /// Coordinates, not a rounded key. This was a string of both values cut to
  /// four decimals — about eleven metres — and compared for equality, which
  /// sounds like "same place" and is not: a fix indoors wanders further than
  /// that between readings, so almost every tick produced a different key and
  /// the repeat suppression never once fired. A log four minutes long showed
  /// the beacon going out at 45-second intervals without a single gap, from a
  /// phone on a desk.
  double? _lastSentLat;
  double? _lastSentLon;

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
    _lastSentLat = null;
    _lastSentLon = null;
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
      if (PlatformInfo.isIOS && ref.read(backgroundModeProvider)) {
        // Always authorisation has just been granted or confirmed, and that is
        // the only thing the significant-change doorbell was ever waiting for.
        // It tried to arm at boot, when there was nothing to arm with.
        unawaited(IosSignificantLocation.instance.start());
      }
      if (PlatformInfo.isAndroid && ref.read(backgroundModeProvider)) {
        // The mesh service usually starts at boot, i.e. before location was
        // ever granted — so it is running as a connectedDevice service only,
        // and this stream would be cut off the moment the app leaves the
        // screen. Starting it again re-promotes it with the `location` type
        // it can now claim. Idempotent; the service is already up.
        unawaited(BackgroundService.instance.start());
      }
      _watch = service.watch().listen(
        (fix) {
          _noteFix(fix);
          unawaited(_publish(fix));
        },
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
    // What the subscription last delivered, if it is recent. Asking the phone
    // to find itself again forty-five seconds after it just said where it was
    // is two radios' worth of work for one pin — and on the map screen it was
    // three, since that screen runs its own refresh as well.
    final known = ref.read(lastLocationFixProvider)?.fresh;
    if (known != null) {
      await _publish(known, force: force);
      return;
    }
    // Parked: keep trying to *send*, never to locate. Asking the phone to find
    // itself so the answer can fail to reach anybody is the whole cost this
    // guard exists to avoid — and a send that succeeds from a stale fix is
    // what un-parks it.
    if (!_beaconIsLanding) return;
    final (fix, _) = await const LocationService().current();
    if (fix == null) return;
    _noteFix(fix);
    await _publish(fix, force: force);
  }

  /// How far the pin may drift and still count as not having moved.
  ///
  /// Matched to the position stream's own `distanceFilter`, which is what
  /// decides when a *new* fix is even delivered — anything under it is noise
  /// the map would not draw differently anyway.
  static const double _samePlaceMetres = 40;

  bool _isNearLastSent(LocationFix fix) {
    final lat = _lastSentLat;
    final lon = _lastSentLon;
    if (lat == null || lon == null) return false;
    // Equirectangular approximation. Exact enough by a wide margin at forty
    // metres, and it costs two multiplications instead of a haversine.
    const metresPerDegree = 111320.0;
    final dLat = (fix.latitude - lat) * metresPerDegree;
    final dLon = (fix.longitude - lon) *
        metresPerDegree *
        math.cos(lat * math.pi / 180);
    return dLat * dLat + dLon * dLon <= _samePlaceMetres * _samePlaceMetres;
  }

  void _noteFix(LocationFix fix) => ref
      .read(lastLocationFixProvider.notifier)
      .state = StampedLocationFix(fix, DateTime.now());

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
      if (!force &&
          _lastSentAt != null &&
          now.difference(_lastSentAt!) < _repeatSamePlaceAfter &&
          _isNearLastSent(fix)) {
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
      var sent = 0;
      for (final peerId in peers) {
        try {
          await messaging.sendText(peerId, share, transient: true);
          sent++;
        } catch (e) {
          debugPrint('MapPresenceController send failed for $peerId: $e');
        }
      }
      // Only a beacon that got out counts against the next one. Marking the
      // attempt regardless meant a failure — the transport still starting up,
      // most often — bought thirty-five seconds of deliberate silence on top
      // of it.
      if (sent > 0) {
        _lastSentLat = fix.latitude;
        _lastSentLon = fix.longitude;
        _lastSentAt = now;
        // Somebody is listening again: pick the radio back up if it was parked.
        final wasIdle = !_beaconIsLanding;
        _deadRounds = 0;
        if (wasIdle) {
          DebugLog.instance
              .log('MAP', 'beacon landed again — resuming location updates');
          unawaited(_startWatching());
        }
      } else {
        _deadRounds++;
        if (!_beaconIsLanding && _watch != null) {
          DebugLog.instance.log(
            'MAP',
            'no map friend reachable for $_deadRounds rounds — '
                'parking location updates',
          );
          unawaited(_stopWatching());
        }
      }
    } finally {
      _sending = false;
    }
  }
}

final mapPresenceControllerProvider =
    NotifierProvider<MapPresenceController, int>(MapPresenceController.new);
