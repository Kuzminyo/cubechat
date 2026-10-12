import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What this build can actually do, asked in one place.
///
/// The phone is the whole product; a computer is a relay-only client with no
/// Bluetooth stack, no Google map SDK (it draws tiles), no camera plugin, a WebRTC copy built for the
/// phones only, ML Kit only on the phones and no phone gallery. Screens ask
/// these flags rather than `Platform.isWindows`, so the list of what a desktop
/// hides lives here and not as a check scattered over every screen — see
/// docs/superpowers/specs/2026-10-10-windows-desktop-design.md.
@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.bluetooth,
    required this.maps,
    required this.googleMaps,
    required this.shareLocation,
    required this.camera,
    required this.calls,
    required this.translation,
    required this.gallery,
  });

  /// The mesh, Nearby and AirDrop.
  final bool bluetooth;

  /// The Map tab, to look at where map friends are.
  final bool maps;

  /// Google's map SDK, which has no Windows build. Without it the map is drawn
  /// from tiles by flutter_map (asked for on 2026-10-12).
  final bool googleMaps;

  /// Sending this device's position as the person's. A phone only: a
  /// computer carries a copy of the phone's account, switch and friends
  /// included, and beaconing from both would put one person in two places —
  /// the pin jumping between the pocket and the desk.
  final bool shareLocation;

  /// Taking a photo or a circle in the app.
  final bool camera;
  final bool calls;

  /// On-device translation of a message.
  final bool translation;

  /// The phone's photo library as a grid; without it, a file picker.
  final bool gallery;

  static const PlatformCapabilities phone = PlatformCapabilities(
    bluetooth: true,
    maps: true,
    googleMaps: true,
    shareLocation: true,
    camera: true,
    calls: true,
    translation: true,
    gallery: true,
  );

  static const PlatformCapabilities desktop = PlatformCapabilities(
    bluetooth: false,
    maps: true,
    googleMaps: false,
    shareLocation: false,
    camera: false,
    calls: false,
    translation: false,
    gallery: false,
  );

  static PlatformCapabilities forPlatform(
    TargetPlatform platform, {
    bool web = false,
  }) {
    if (web) return desktop;
    return switch (platform) {
      TargetPlatform.android || TargetPlatform.iOS => phone,
      _ => desktop,
    };
  }

  static PlatformCapabilities get current =>
      forPlatform(defaultTargetPlatform, web: kIsWeb);
}

/// [PlatformCapabilities.current], as a provider a test can override.
final platformCapabilitiesProvider =
    Provider<PlatformCapabilities>((_) => PlatformCapabilities.current);
