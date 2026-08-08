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

/// One position, asked for at the moment the user taps Send.
///
/// Deliberately a single reading rather than a subscription. Live location is a
/// different feature with a different bill — a stream the app has to keep
/// running, a radio it has to keep awake, and a promise to stop that has to
/// survive being killed — and this app has spent enough of this week finding
/// out what always-on costs. A snapshot is what "share where I am" usually
/// means anyway.
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
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return (
        LocationFix(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracyMetres: position.accuracy.isFinite
              ? position.accuracy.round().clamp(0, 65535)
              : 0,
        ),
        null,
      );
    } catch (e) {
      // A timeout, no fix indoors, a platform that has no idea — all the same
      // answer to the caller, which is "we could not, say so and move on".
      DebugLog.instance.log('LOCATION', 'fix failed: $e');
      return (null, LocationFailure.unavailable);
    }
  }
}
