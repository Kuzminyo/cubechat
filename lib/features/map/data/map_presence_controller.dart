import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/shared_location.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/location_service.dart';
import '../../chat/models/message.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/models/known_peer.dart';
import '../../profile/data/privacy_settings_controller.dart';
import 'map_friends_controller.dart';

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

  /// How old a fix may be and still stand in for a new one.
  static const stillGood = Duration(seconds: 60);

  LocationFix? get fresh =>
      DateTime.now().difference(at) <= stillGood ? fix : null;
}

/// The last position the app obtained, from whichever consumer obtained it.
///
/// A plain state provider rather than a getter on the check-in controller, so
/// the map screen can read it without bringing that controller to life.
final lastLocationFixProvider = StateProvider<StampedLocationFix?>((_) => null);

/// Where this phone is, asked once. Overridden in tests.
typedef MapLocationReader = Future<(LocationFix?, LocationFailure?)> Function();

final mapLocationReaderProvider = Provider<MapLocationReader>(
  (ref) => const LocationService().current,
);

/// Put one map position in front of one peer. True when it went somewhere
/// rather than into the queue for later. Overridden in tests.
typedef MapBeaconSender = Future<bool> Function(String peerId, String text);

final mapBeaconSenderProvider = Provider<MapBeaconSender>((ref) {
  return (peerId, text) async {
    final message = await ref
        .read(messagingServiceProvider)
        .sendText(peerId, text, transient: true);
    return message.route != MessageRoute.queued;
  };
});

/// What a check-in came to, for the screen to say.
enum CheckInResult {
  done,

  /// The person has not agreed to be shown on a map. Nothing was located.
  noConsent,

  /// Nobody to show it to: no map friends, or every one of them blocked.
  nobodyToShow,

  /// The phone could not say where it is.
  noFix,

  /// A position was taken and reached nobody.
  unreachable,
}

/// A position on a friend's map is a check-in, made by hand, each time.
///
/// **This was a live map, and App Store review rejected it.** Under guideline
/// 5.1.2(i) Apple requires, for an app that displays users' locations on a map,
/// that a person "manually check in each time they wish to have their location
/// displayed on a map; there should be no option to enable automatic check
/// ins". Until this, sharing was a switch: once on, a 45-second timer and a
/// background position subscription — and on iOS a relaunch whenever the phone
/// moved — kept a friend's map current with no further action. That is the
/// automatic check-in the review named, and all of it is gone: no timer, no
/// subscription, nothing that runs in the background, nothing that publishes on
/// its own. The cost of all that machinery, measured over many builds, goes with
/// it.
///
/// What is left is one method a person calls with a button. It asks the phone
/// where it is once, sends that position to each map friend who is not blocked,
/// and tells them it stops being current in [checkInLasts]. The receiver
/// removes it when that passes (see `MapPresenceStore`), so an hour means an
/// hour. [withdraw] takes it back sooner.
///
/// The switch in Privacy is still here, and means consent: without it a
/// check-in does nothing, and asks for no location. Turning it off takes back
/// whatever is showing. The state is when the current check-in stops being
/// visible, or null.
class MapPresenceController extends Notifier<DateTime?> {
  /// How long a check-in stays on a friend's map. One hour: long enough for
  /// somebody to see where you are, short enough that an old pin does not stand
  /// in for where you have since gone. Chosen by the product owner.
  static const checkInLasts = Duration(hours: 1);

  bool _busy = false;

  /// Who was sent the current check-in, so a block can take it back from them.
  Set<String> _showing = const {};

  @override
  DateTime? build() {
    ref.listen<PrivacySettings>(privacySettingsProvider, (before, after) {
      // Consent withdrawn takes back what is showing, rather than only
      // declining to send more — the switch means nobody sees where I am.
      if ((before?.shareMapLocation ?? false) && !after.shareMapLocation) {
        unawaited(withdraw());
      }
    });
    ref.listen<Map<String, KnownPeer>>(knownPeersControllerProvider,
        (before, after) {
      // Blocking somebody who can currently see this phone on their map takes
      // the pin back from them at once. Apple requires a way to block other
      // users, and a block that left your position standing on the blocked
      // person's map for the rest of the hour would not be one.
      final newlyBlocked = [
        for (final id in _showing)
          if ((after[id]?.isBlocked ?? false) &&
              !(before?[id]?.isBlocked ?? false))
            id,
      ];
      if (newlyBlocked.isEmpty) return;
      _showing = {..._showing}..removeAll(newlyBlocked);
      unawaited(_retract(newlyBlocked));
    });
    return null;
  }

  /// Map friends a check-in may go to: every one not blocked.
  List<String> _audience() {
    final peers = ref.read(knownPeersControllerProvider);
    return [
      for (final id in ref.read(mapFriendsControllerProvider))
        if (!(peers[id]?.isBlocked ?? false)) id,
    ];
  }

  /// Show this phone's position to map friends, once, for [checkInLasts].
  Future<CheckInResult> checkIn() async {
    if (_busy) return CheckInResult.unreachable;
    if (!ref.read(privacySettingsProvider).shareMapLocation) {
      _log('check-in refused: no consent');
      return CheckInResult.noConsent;
    }
    final audience = _audience();
    if (audience.isEmpty) {
      _log('check-in refused: no unblocked map friend');
      return CheckInResult.nobodyToShow;
    }
    _busy = true;
    try {
      final (fix, failure) = await ref.read(mapLocationReaderProvider)();
      if (fix == null) {
        _log('check-in: no position (${failure?.name ?? 'unknown'})');
        return CheckInResult.noFix;
      }
      ref.read(lastLocationFixProvider.notifier).state =
          StampedLocationFix(fix, DateTime.now());
      final until = DateTime.now().add(checkInLasts);
      final text = SharedLocation(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyMetres: fix.accuracyMetres,
        expiresAt: until,
        presence: true,
      ).encode();
      final send = ref.read(mapBeaconSenderProvider);
      final reached = <String>{};
      for (final peerId in audience) {
        try {
          if (await send(peerId, text)) reached.add(peerId);
        } catch (e) {
          debugPrint('check-in to $peerId failed: $e');
        }
      }
      _log('check-in: ${reached.length} of ${audience.length} friend(s), '
          'visible for ${checkInLasts.inMinutes} min');
      if (reached.isEmpty) return CheckInResult.unreachable;
      _showing = reached;
      state = until;
      return CheckInResult.done;
    } finally {
      _busy = false;
    }
  }

  /// Take the current check-in back from every map friend, now.
  ///
  /// A flagged, already-expired beacon rather than a new payload type: the
  /// receiver reads the flag as "remove this person", and an older build sees
  /// a position that expired before it arrived.
  Future<void> withdraw() async {
    state = null;
    _showing = const {};
    final peers =
        ref.read(mapFriendsControllerProvider).toList(growable: false);
    if (peers.isEmpty) return;
    _log('check-in withdrawn from ${peers.length} friend(s)');
    await _retract(peers);
  }

  Future<void> _retract(Iterable<String> peerIds) async {
    final gone = SharedLocation(
      latitude: 0,
      longitude: 0,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      presence: true,
      retract: true,
    ).encode();
    final send = ref.read(mapBeaconSenderProvider);
    for (final peerId in peerIds) {
      try {
        await send(peerId, gone);
      } catch (e) {
        debugPrint('withdrawing the check-in from $peerId failed: $e');
      }
    }
  }

  static void _log(String line) => DebugLog.instance.log('MAP', line);
}

final mapPresenceControllerProvider =
    NotifierProvider<MapPresenceController, DateTime?>(
  MapPresenceController.new,
);
