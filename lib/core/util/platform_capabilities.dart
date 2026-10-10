import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What this build can actually do, asked in one place.
///
/// The phone is the whole product; a computer is a relay-only client with no
/// Bluetooth stack, no map SDK, no camera plugin, a WebRTC copy built for the
/// phones only, ML Kit only on the phones and no phone gallery. Screens ask
/// these flags rather than `Platform.isWindows`, so the list of what a desktop
/// hides lives here and not as a check scattered over every screen — see
/// docs/superpowers/specs/2026-10-10-windows-desktop-design.md.
@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.bluetooth,
    required this.maps,
    required this.camera,
    required this.calls,
    required this.translation,
    required this.gallery,
  });

  /// The mesh, Nearby and AirDrop.
  final bool bluetooth;
  final bool maps;

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
    camera: true,
    calls: true,
    translation: true,
    gallery: true,
  );

  static const PlatformCapabilities desktop = PlatformCapabilities(
    bluetooth: false,
    maps: false,
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
