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
import '../../chat/models/message.dart';
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

  /// How long a published pin stays on a friend's map without a refresh.
  ///
  /// Two minutes with a 70-second repeat meant a phone standing still
  /// republished an identical position about every 90 seconds, for ever. In a
  /// 72-minute log that was **191 of 274 relay publishes** — 70% of everything
  /// the radio did, and 70% of the X3DH derivations and Schnorr signatures,
  /// to carry 55 kB. It also filled the debug buffer: 967 of 1000 lines were
  /// this, so nothing else on that phone could be diagnosed at all.
  ///
  /// Six minutes, refreshed at four, is the same pin at a third of the cost.
  /// Nothing about a *moving* phone changes: a changed position was never
  /// throttled and still is not, so somebody being followed on the map updates
  /// exactly as before. What gets slower is the pin of somebody who stopped —
  /// and the case that actually matters there, switching sharing off, does not
  /// wait for a TTL at all: `withdraw` retracts immediately.
  static const _ttl = Duration(minutes: 6);

  /// How long the same position may go unrepeated.
  ///
  /// A beacon carries [_ttl], so a pin that stops being refreshed disappears
  /// when that lapses; re-sending is only ever about staying inside it. The
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
  ///
  /// Raised to four minutes with [_ttl] at six, once the 90-second figure was
  /// measured rather than reasoned about: 191 of 274 publishes in 72 minutes,
  /// from a phone that had not moved. Four minutes against a six-minute TTL
  /// keeps two minutes of margin — the same proportion 70 s kept against two
  /// minutes — and cuts a standing phone's beacons from about 40 an hour to
  /// 15. Still unchanged for a phone in motion.
  static const _repeatSamePlaceAfter = Duration(minutes: 4);

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

  /// Map friends we have already complained about being unable to reach.
  /// Cleared for a peer the moment a send to them succeeds, so a transport
  /// that comes back is reported once too rather than staying silent.
  final Set<String> _reportedUnreachable = <String>{};

  /// About two minutes at [_tick]. Long enough to ride out a transport that is
  /// still coming up after a launch, which is the ordinary reason a beacon
  /// fails, and short enough that a dead friend list does not cost an evening.
  static const _deadRoundsBeforeIdle = 3;

  bool get _beaconIsLanding => _deadRounds < _deadRoundsBeforeIdle;

  /// Consecutive attempts to locate this phone that produced nothing.
  ///
  /// Distinct from [_deadRounds], which counts rounds that reached nobody. A
  /// phone can be perfectly able to send and completely unable to say where it
  /// is — indoors, location services off, a chip that has lost the sky — and
  /// that state was costing a twenty-second GPS session every other tick with
  /// no end to it.
  int _lostRounds = 0;

  /// Three, matching [_deadRoundsBeforeIdle]: long enough to ride out a cold
  /// start under a roof, short enough that a phone in a drawer stops paying.
  static const _lostRoundsBeforeIdle = 3;

  bool get _canLocate => _lostRounds < _lostRoundsBeforeIdle;
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

  /// Publish now, out of turn — a background window asking for the pin.
  ///
  /// [offered] is a position the caller already has and did not pay for: the
  /// coarse fix iOS hands over when a significant-change event relaunches the
  /// app. Preferring it is the whole point of accepting it — the alternative
  /// is a cold `getCurrentPosition` in the background, and background GPS is
  /// the largest single expense this app has ever been measured making. Stale
  /// or absent, the ordinary route runs unchanged.
  /// Publish now, from a position somebody else already has.
  ///
  /// The iOS doorbell's path: a closed app is relaunched because the phone
  /// moved, CoreLocation hands the position over with the wake, and this puts
  /// it on the map.
  ///
  /// **Waits for the two settings it is about to read.** Both live in the
  /// encrypted settings box and both start at their defaults — "not sharing"
  /// and "no friends" — until it opens. In the app that is invisible, because
  /// nothing asks in the first second of a launch anybody is looking at. On a
  /// relaunch there is no first second: there is no UI at all, this runs
  /// immediately, and it read "sharing is off, and with nobody" every single
  /// time. Which is indistinguishable, from the outside, from the feature not
  /// existing — reported as location never being sent from a closed phone,
  /// with the permission granted and the switch on.
  ///
  /// Awaiting a future that has already completed costs nothing, so the
  /// ordinary path pays nothing for this.
  Future<void> pokeNow({StampedLocationFix? offered}) async {
    await ref.read(privacySettingsProvider.notifier).loaded;
    await ref.read(mapFriendsControllerProvider.notifier).loaded;
    // Said out loud, because the silence is what hid this.
    //
    // `_sendUpdate` returns on its first line when sharing is off or the
    // friend list is empty, and it says nothing when it does — which is right
    // for a timer that fires every forty-five seconds and wrong for the one
    // moment a closed phone gets. "Nothing in the log" and "it decided not to"
    // looked the same from here for as long as this has existed.
    final friends = ref.read(mapFriendsControllerProvider).length;
    final on = ref.read(privacySettingsProvider).shareMapLocation;
    DebugLog.instance.log(
      'MAP',
      'wake poke: sharing ${on ? "on" : "off"}, $friends friend(s)'
          '${offered == null ? ", no position offered" : ""}',
    );
    await _sendUpdate(force: true, offered: offered);
  }

  /// Take a fix and publish it. The timer's half of the job.
  Future<void> _sendUpdate({
    bool force = false,
    StampedLocationFix? offered,
  }) async {
    if (_sending || !_shouldShare) return;
    // A position handed in from outside beats one this has to go and find, and
    // it is judged by the same clock as any other — see [pokeNow].
    final given = offered?.fresh;
    if (given != null) {
      _noteStamped(offered!);
      await _publish(given, force: force);
      return;
    }
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
    // And parked separately when the phone cannot find *itself*.
    //
    // [_beaconIsLanding] answers "is anybody receiving this", which is a
    // different question from "can this phone produce a position at all", and
    // only the first had a brake. A field log has six of these ninety seconds
    // apart, unbroken:
    //
    //     [LOCATION] live fix failed (TimeoutException after 0:00:20) —
    //     using last known
    //
    // Twenty seconds of GPS held on, every other tick, for ever, ending in the
    // stale coordinate it would have used anyway. A phone indoors or with
    // location services off is not a rare state and it does not resolve by
    // being asked again a minute later.
    if (!_canLocate) return;
    final (fix, _) = await const LocationService().current();
    if (fix == null) {
      _lostRounds++;
      if (!_canLocate) {
        DebugLog.instance.log(
          'MAP',
          'cannot get a fix after $_lostRounds tries — parking the radio '
              'until one arrives on its own',
        );
      }
      return;
    }
    _lostRounds = 0;
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

  void _noteFix(LocationFix fix) =>
      _noteStamped(StampedLocationFix(fix, DateTime.now()));

  /// Publish a fix to everything else that wants to know where this phone is.
  ///
  /// Stamped by whoever took it, not by the moment it was filed: a position
  /// that arrived with a background wake-up is already several seconds old by
  /// the time Dart has booted enough to look at it, and re-dating it here
  /// would hide exactly the staleness the next reader is checking for.
  void _noteStamped(StampedLocationFix stamped) {
    // Any position at all un-parks the locating, wherever it came from — the
    // subscription, a background wake-up, the map screen's own refresh. The
    // park exists because asking again immediately is futile, not because the
    // phone is written off: the moment one arrives on its own, the reason to
    // hold back is gone.
    _lostRounds = 0;
    ref.read(lastLocationFixProvider.notifier).state = stamped;
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
          // Delivered, not merely attempted.
          //
          // This used to count every call that did not throw, and a beacon
          // with nowhere to go does not throw — `sendText` logs "found no
          // route" and returns normally. So `sent` was the number of peers in
          // the list, never zero, and the whole branch below that parks the
          // GPS when nobody is receiving could not be reached. The fix is in
          // what `sendText` returns, and this is the half that reads it.
          final outcome =
              await messaging.sendText(peerId, share, transient: true);
          if (outcome.route != MessageRoute.queued) {
            sent++;
            _reportedUnreachable.remove(peerId);
          }
        } catch (e) {
          // Once per peer, not once per tick.
          //
          // A map friend whose pubkey no longer resolves — left behind by a
          // restore, most often — fails identically every thirty-five seconds
          // for as long as sharing is on. In a 200-line log buffer that is a
          // hundred and seventy lines of the same sentence, and it evicts the
          // evidence of whatever was actually being investigated. The fact is
          // worth exactly one line: it does not change until something else
          // does.
          if (_reportedUnreachable.add(peerId)) {
            debugPrint('MapPresenceController send failed for $peerId: $e');
          }
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
