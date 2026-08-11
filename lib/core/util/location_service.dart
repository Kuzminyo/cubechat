import 'package:geolocator/geolocator.dart';

import 'debug_log.dart';
import 'platform_info.dart';

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
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          // Medium, not best. A shared pin is read at street level, and the
          // last few metres of precision cost seconds of the radio staying up
          // — which is the sort of thing that adds up on a phone this app is
          // otherwise careful with.
          accuracy: _accuracy,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return (_fixOf(position), null);
    } catch (e) {
      // A timeout, no fix indoors, a platform that has no idea — all the same
      // answer to the caller, which is "we could not, say so and move on".
      DebugLog.instance.log('LOCATION', 'fix failed: $e');
      return (null, LocationFailure.unavailable);
    }
  }

  /// Positions for as long as somebody is on the map with you — including
  /// while the app is out of sight.
  ///
  /// The opposite trade-off from [current], and deliberately not the default:
  /// this is a subscription the OS keeps alive, which is the whole point (a
  /// pin that freezes the moment its owner locks the phone answers "where were
  /// they when they last looked at their map", which is not the question) and
  /// also the whole cost. It runs only while map sharing is on *and* somebody
  /// is actually receiving it — see MapPresenceController.
  ///
  /// [_watchDistanceMetres] rather than a clock does the throttling, because
  /// standing still is the common case and a phone that has not moved has
  /// nothing to say. It is also what keeps this affordable: no movement, no
  /// wake-ups, no radio.
  Stream<LocationFix> watch() =>
      Geolocator.getPositionStream(locationSettings: _watchSettings())
          .map(_fixOf);

  /// Ask for the permission a background heartbeat needs, and say whether we
  /// got it.
  ///
  /// On iOS this is "Always": "While Using" stops the updates at the moment
  /// the app leaves the screen, which is exactly the case this exists for.
  /// geolocator escalates a second [Geolocator.requestPermission] on an
  /// already-granted while-in-use into the Always prompt, provided
  /// `NSLocationAlwaysAndWhenInUseUsageDescription` is in Info.plist.
  ///
  /// Android needs no equivalent ask: the app already runs a foreground
  /// service, and a service declaring the `location` type carries foreground
  /// location access with it for as long as it is up.
  Future<bool> ensureBackgroundPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return false;
      }
      if (PlatformInfo.isIOS && permission == LocationPermission.whileInUse) {
        // Best effort. iOS shows this at most once and may defer it until the
        // app has actually used location in the background; while-in-use is
        // still worth streaming with in the meantime, so a "no" here is not a
        // reason to give up on the feature.
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (e) {
      DebugLog.instance.log('LOCATION', 'background permission failed: $e');
      return false;
    }
  }

  static LocationFix _fixOf(Position position) => LocationFix(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMetres:
            position.accuracy.isFinite ? position.accuracy.round().clamp(0, 65535) : 0,
      );

  static LocationSettings _watchSettings() {
    if (PlatformInfo.isAndroid) {
      return AndroidSettings(
        accuracy: _accuracy,
        distanceFilter: _watchDistanceMetres,
        intervalDuration: const Duration(seconds: 45),
        // No foregroundNotificationConfig on purpose: cubechat already runs
        // MeshForegroundService, which now declares the `location` type, and
        // letting geolocator start a second foreground service would put two
        // permanent notifications in the shade for one app.
      );
    }
    if (PlatformInfo.isIOS) {
      return AppleSettings(
        accuracy: _accuracy,
        distanceFilter: _watchDistanceMetres,
        // The three that decide whether this survives leaving the screen:
        // background updates allowed at all, iOS not pausing them on its own
        // judgement of "stationary enough", and the blue indicator — which is
        // not optional and should not be: an app sending your position while
        // you are elsewhere ought to be saying so on the status bar.
        allowBackgroundLocationUpdates: true,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        activityType: ActivityType.other,
      );
    }
    return const LocationSettings(
      accuracy: _accuracy,
      distanceFilter: _watchDistanceMetres,
    );
  }

  static const _accuracy = LocationAccuracy.medium;

  /// How far the phone must move before the OS bothers waking us with a fix.
  ///
  /// Roughly a building's width: far enough that GPS jitter on a phone lying
  /// on a table cannot generate traffic, close enough that walking down a
  /// street moves your pin while you are walking it.
  static const _watchDistanceMetres = 30;
}
