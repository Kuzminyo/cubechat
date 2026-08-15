import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// What the map is drawn on.
///
/// Three, not a gallery: each one answers a different question — which street,
/// what is actually there, and what the ground does — and every extra style is
/// another tile service to depend on and another set of squares to cache.
enum MapLayer {
  /// The regular Google/OpenStreetMap street map. It is deliberately the
  /// startup default: the dark custom style is useful, but if it stalls while
  /// the native map view is being recreated the screen looks like it never
  /// loaded.
  standard,

  /// Dark, label-free, and quiet under the pins.
  dark,

  /// Aerial imagery, for "which building, which yard".
  satellite,

  /// Contours and shaded relief, for hills, forest and trails.
  terrain,
}

extension MapLayerTiles on MapLayer {
  String get id => switch (this) {
        MapLayer.standard => 'standard',
        MapLayer.dark => 'dark',
        MapLayer.satellite => 'satellite',
        MapLayer.terrain => 'terrain',
      };

  String get urlTemplate => switch (this) {
        MapLayer.standard => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        MapLayer.dark =>
          'https://{s}.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}{r}.png',
        // Esri's imagery has no subdomains and no retina variant: one host,
        // one size, and {r} would be sent literally if it were left in.
        MapLayer.satellite =>
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery'
              '/MapServer/tile/{z}/{y}/{x}',
        MapLayer.terrain => 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
      };

  List<String> get subdomains => switch (this) {
        MapLayer.standard => const [],
        MapLayer.dark => const ['a', 'b', 'c', 'd'],
        MapLayer.satellite => const [],
        MapLayer.terrain => const ['a', 'b', 'c'],
      };

  /// Retina tiles exist only for the CARTO style; asking the others for `@2x`
  /// gets a 404 per tile.
  bool get supportsRetina => this == MapLayer.dark;

  /// The deepest zoom each service actually renders. Past it flutter_map
  /// upscales the last real tile instead of requesting squares that come back
  /// blank — which is what a bare grid at maximum zoom was.
  int get maxNativeZoom => switch (this) {
        MapLayer.standard => 19,
        MapLayer.dark => 20,
        MapLayer.satellite => 19,
        MapLayer.terrain => 17,
      };

  /// Who has to be credited, as their licence requires.
  List<(String, String)> get attributions => switch (this) {
        MapLayer.standard => const [
            (
              'OpenStreetMap contributors',
              'https://www.openstreetmap.org/copyright'
            ),
          ],
        MapLayer.dark => const [
            (
              'OpenStreetMap contributors',
              'https://www.openstreetmap.org/copyright'
            ),
            ('CARTO', 'https://carto.com/attributions'),
          ],
        MapLayer.satellite => const [
            ('Esri, Maxar, Earthstar Geographics', 'https://www.esri.com/'),
          ],
        MapLayer.terrain => const [
            (
              'OpenStreetMap contributors',
              'https://www.openstreetmap.org/copyright'
            ),
            ('OpenTopoMap (CC-BY-SA)', 'https://opentopomap.org/'),
          ],
      };
}

/// Remembers which basemap the user picked.
class MapLayerController extends Notifier<MapLayer> {
  static const _key = 'map.layer';

  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _changed = false;

  @override
  MapLayer build() {
    unawaited(_loading = _load());
    return MapLayer.standard;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      if (_changed) return;
      final saved = box.get(_key) as String?;
      if (saved == null) return;
      state = MapLayer.values.firstWhere(
        (layer) => layer.id == saved,
        orElse: () => MapLayer.standard,
      );
    } catch (e) {
      debugPrint('MapLayer load failed: $e');
    }
  }

  Future<void> select(MapLayer layer) async {
    if (layer == state) return;
    _changed = true;
    state = layer;
    try {
      // Waits for the box rather than dropping the write into a null one.
      await _loading;
      await _box?.put(_key, layer.id);
    } catch (e) {
      debugPrint('MapLayer persist failed: $e');
    }
  }
}

final mapLayerControllerProvider =
    NotifierProvider<MapLayerController, MapLayer>(MapLayerController.new);
