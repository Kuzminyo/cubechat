import 'package:geolocator/geolocator.dart';

import 'debug_log.dart';

/// What went wrong asking the phone where it is, in terms the UI can act on.
enum LocationFailure { denied, serviceOff, unavailable }

class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMetres,
  });

  final double latitude;
  final double longitude;
  final int accuracyMetres;
}

/// Where the phone is: [current] for one reading, [watch] for a subscription.
///
/// The two are separate on purpose and cost nothing alike. [current] is a
/// snapshot for the moment somebody taps Send, and is what "share where I am"
/// usually means. [watch] is live location — a stream the app keeps running, a
/// radio it keeps awake, and a promise to stop that has to survive being
/// killed — and it stays switched off until somebody turns map sharing on and
/// has friends to send it to.
///
/// Permission is requested here rather than at launch: asking for someone's
/// location before they have asked to send one is how an app teaches people to
/// deny by reflex.
class LocationService {
  const LocationService();

  Future<(LocationFix?, LocationFailure?)> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return (null, LocationFailure.serviceOff);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return (null, LocationFailure.denied);
      }
      // What the platform already knows, before asking it to go and find out.
      //
      // A cold `getCurrentPosition` is seconds of radio even outdoors, and
      // indoors it frequently runs the full twenty and gives up — which is the
      // "it looks for ages and then does not find me" that made the map feel
      // broken every time it was opened. The OS has almost always got a recent
      // fix from some other app; a couple of minutes old is a pin on the right
      // building, and the ninety-second refresh replaces it with a fresh one
      // shortly anyway.
      final cached = await _lastKnown();
      if (cached != null && _worthShowing(cached)) {
        return (_fixOf(cached), null);
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            // Medium, not best. A shared pin is read at street level, and the
            // last few metres of precision cost seconds of the radio staying
            // up — which is the sort of thing that adds up on a phone this app
            // is otherwise careful with.
            accuracy: _accuracy,
            timeLimit: Duration(seconds: 20),
          ),
        );
        return (_fixOf(position), null);
      } catch (e) {
        // Timed out, or no fix to be had where the phone is standing. A stale
        // position is not nothing: it is where the phone last was, which beats
        // an empty map and a failure notice by a wide margin, and it is what
        // every other map app shows in the same moment.
        final stale = cached ?? await _lastKnown();
        if (stale != null) {
          DebugLog.instance.log('LOCATION', 'live fix failed ($e) — using last known');
          return (_fixOf(stale), null);
        }
        rethrow;
      }
    } catch (e) {
      // A timeout, no fix indoors, a platform that has no idea — all the same
      // answer to the caller, which is "we could not, say so and move on".
      DebugLog.instance.log('LOCATION', 'fix failed: $e');
      return (null, LocationFailure.unavailable);
    }
  }

  /// The platform's own cached position, or null. Never throws: on a phone
  /// that has none this is simply absent, which is not a failure worth
  /// reporting to anybody.
  Future<Position?> _lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (e) {
      DebugLog.instance.log('LOCATION', 'last known unavailable: $e');
      return null;
    }
  }

  /// Whether the platform's cached fix is worth showing instead of waiting for
  /// a real one.
  ///
  /// Age was the only test, and on iOS that is not enough: CoreLocation hands
  /// back a *recent* fix that can be a cell-tower estimate kilometres wide, so
  /// "two minutes old" was being shown as a pin on a street the phone had
  /// never been on. Accuracy has to pass too — a fix that only knows the
  /// district is worse than a second of waiting.
  static bool _worthShowing(Position position) {
    if (DateTime.now().difference(position.timestamp) >= _cacheStillGood) {
      return false;
    }
    final accuracy = position.accuracy;
    return accuracy.isFinite && accuracy > 0 && accuracy <= _cacheMaxErrorMetres;
  }

  /// How old the platform's cached fix may be and still be worth showing.
  /// Long enough to cover walking indoors and opening the app; short enough
  /// that it cannot put somebody on the wrong street.
  static const _cacheStillGood = Duration(minutes: 2);

  /// And how wrong it may be. Past this it is a neighbourhood, not a position,
  /// and the map would be drawing confidence it does not have.
  static const double _cacheMaxErrorMetres = 120;

  // A position subscription that ran while the app was out of sight, and the
  // "Always" permission it asked for, lived here. Both served the live map,
  // which App Store review rejected under guideline 5.1.2(i): a location is
  // shown on a map only when a person checks in, by hand, each time. A check-in
  // is one [current] fix taken while the person is looking at the map, so
  // nothing here runs in the background, and nothing asks for more than
  // while-in-use.

  static LocationFix _fixOf(Position position) => LocationFix(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMetres:
            position.accuracy.isFinite ? position.accuracy.round().clamp(0, 65535) : 0,
      );

  /// High, not medium.
  ///
  /// Medium is `kCLLocationAccuracyHundredMeters` on iOS, and a hundred metres
  /// is a different building — sometimes a different street. It was chosen to
  /// keep the radio down, back when the pin was a one-off share; a live map
  /// that puts a friend on the wrong corner is not cheaper, it is wrong. Best
  /// is still not asked for: that is the last few metres, and they cost the
  /// most seconds of GPS for the least difference on a map read at street
  /// level.
  static const _accuracy = LocationAccuracy.high;
}
