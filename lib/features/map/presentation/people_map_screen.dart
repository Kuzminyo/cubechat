import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/identity/avatar_controller.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/util/app_lifecycle.dart';
import '../../../core/util/location_service.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/data/peer_avatars_controller.dart';
import '../../profile/data/privacy_settings_controller.dart';
import '../data/map_address_service.dart';
import '../data/map_clusters.dart';
import '../data/map_focus_request.dart';
import '../data/map_layer_controller.dart';
import '../data/map_presence_controller.dart';
import '../data/shared_map_locations_provider.dart';
import 'map_cluster_sheet.dart';
import 'map_friends_sheet.dart';
import 'map_layer_sheet.dart';
import 'dart:io' show Platform;
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:dio_cache_interceptor_file_store/dio_cache_interceptor_file_store.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/util/debug_log.dart';

typedef MapLocationReader = Future<(LocationFix?, LocationFailure?)> Function();
typedef MapAddressReader = Future<String?> Function(
  double latitude,
  double longitude,
  Locale locale,
);

/// Tiles, cached on disk.
///
/// Null meant flutter_map's plain network provider: every pan and every zoom
/// step re-fetched squares the phone had already seen, there was no map at all
/// without a connection, and a fast pinch turned into a burst of hundreds of
/// simultaneous requests and decodes — which is what was taking the app down.
///
/// A disk cache answers all three. It also keeps the app a good citizen of a
/// free tile service: the same square is asked for once rather than once per
/// gesture.
///
/// Overridden with null in widget tests, which have no HTTP and no cache
/// directory — see [PeopleMapScreen.tileProvider].
final mapTileProviderProvider = Provider<TileProvider?>((ref) {
  final store = _tileCacheStore;
  if (store == null) return null;
  return CachedTileProvider(
    maxStale: const Duration(days: 30),
    store: store,
  );
});

/// Opened once at startup — see [initMapTileCache]. Held here rather than
/// created lazily because building it needs a directory, which is async, and a
/// provider that returns a future would make every rebuild of the map wait.
CacheStore? _tileCacheStore;

/// Prepare the on-disk tile cache. Safe to call more than once.
///
/// Failure is not fatal: without a store the map falls back to fetching every
/// tile, which is how it behaved before there was a cache at all.
Future<void> initMapTileCache() async {
  if (_tileCacheStore != null) return;
  try {
    final dir = await getApplicationCacheDirectory();
    // Deliberately the *cache* directory, unlike conversation media: a tile is
    // reconstructible from the network and nobody loses anything if the OS
    // reclaims the space. See [mediaDirectory] for the opposite case.
    _tileCacheStore = FileCacheStore('${dir.path}${Platform.pathSeparator}map_tiles');
  } catch (e) {
    DebugLog.instance.log('MAP', 'tile cache unavailable: $e');
  }
}
final mapLocationReaderProvider = Provider<MapLocationReader>(
  (ref) => const LocationService().current,
);
final mapAddressReaderProvider = Provider<MapAddressReader>(
  (ref) => const MapAddressService().read,
);

class PeopleMapScreen extends ConsumerStatefulWidget {
  const PeopleMapScreen({super.key, this.tileProvider});

  final TileProvider? tileProvider;

  @override
  ConsumerState<PeopleMapScreen> createState() => _PeopleMapScreenState();
}

class _PeopleMapScreenState extends ConsumerState<PeopleMapScreen>
    with SingleTickerProviderStateMixin {
  static const _fallbackCenter = LatLng(50.4501, 30.5234);
  static const _initialZoom = 13.5;

  /// Where the camera lands when it is pointed at a person. See [_focusOn].
  ///
  /// Close enough to tell which building, not merely which block — pointing the
  /// camera at somebody answers "where exactly", and 16.5 still left a
  /// neighbourhood on screen. Held one step below [MapOptions.maxZoom] so there
  /// is somewhere left to pinch.
  static const _focusZoom = 17.5;
  final _map = MapController();
  final _distance = const Distance();

  LocationFix? _me;
  LocationFailure? _failure;
  Timer? _refresh;
  Timer? _addressDebounce;
  bool _addressReading = false;
  bool _locating = false;
  bool _watching = false;
  bool _centered = false;
  bool _mineSelected = false;
  String? _selectedId;
  String? _centerAddress;
  String? _addressCell;
  LatLng? _queuedAddressPoint;
  String? _queuedAddressCell;
  int _addressRequest = 0;

  /// Drives the camera between two positions instead of teleporting it.
  ///
  /// [MapController.move] is a jump cut: the whole world changes under your
  /// thumb in one frame, and with a 90-second refresh re-centring on a fix that
  /// drifted twenty metres, the map appeared to twitch for no reason anyone
  /// watching could connect to anything. Interpolating turns that into a move
  /// the eye can follow — and, when the fix has barely changed, into something
  /// small enough not to notice at all.
  late final AnimationController _camera = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  LatLng? _cameraFrom;
  LatLng? _cameraTo;
  double? _zoomFrom;
  double? _zoomTo;

  /// True while north is not up, which is the only time the compass is worth
  /// the corner it occupies.
  bool _rotated = false;

  /// The zoom the pins are currently sized for.
  ///
  /// Pins used to be one size at every zoom, so pulling back to see a city
  /// turned a handful of friends into one lump of overlapping discs covering
  /// the streets they were on. Tracked in steps rather than continuously: a
  /// pinch would otherwise rebuild every marker on every frame of the gesture,
  /// and a quarter of a zoom level is finer than the eye follows anyway.
  double _markerZoom = _initialZoom;

  /// Pin size relative to its close-up size, in four steps.
  ///
  /// Steps rather than a smooth curve, and that is about memory rather than
  /// looks. An avatar is decoded at the size it is drawn, so every distinct
  /// size is its own bitmap in the image cache — a continuous scale meant a
  /// fresh decode of every face on screen at every quarter of a zoom level,
  /// and a pinch across a city left dozens of copies of each. On a phone with
  /// eighty pins that is how a map gets killed for memory, which is what iOS
  /// was doing.
  double get _markerScale {
    final zoom = _markerZoom;
    if (zoom >= 14) return 1;
    if (zoom >= 11) return 0.85;
    if (zoom >= 8) return 0.7;
    return 0.55;
  }

  /// The marker's hit box, which has to follow the drawing or a shrunken pin
  /// keeps a full-size tap target and steals its neighbours' taps.
  double get _markerBox => 72 * _markerScale;

  /// Cached link geometry, rebuilt only when the points actually move.
  ///
  /// [_lines] is O(n²) with a sort inside the loop, and it used to run on every
  /// build — which on this screen means every location fix, every beacon from
  /// every friend, and every frame of a camera animation.
  List<Polyline>? _cachedLines;
  String? _cachedLinesKey;

  @override
  void initState() {
    super.initState();
    _camera.addListener(_tickCamera);
  }

  void _tickCamera() {
    final from = _cameraFrom;
    final to = _cameraTo;
    if (from == null || to == null) return;
    final k = Curves.easeInOutCubic.transform(_camera.value);
    _map.move(
      LatLng(
        from.latitude + (to.latitude - from.latitude) * k,
        from.longitude + (to.longitude - from.longitude) * k,
      ),
      (_zoomFrom ?? _initialZoom) +
          ((_zoomTo ?? _initialZoom) - (_zoomFrom ?? _initialZoom)) * k,
    );
  }

  /// Put [point] in the middle and get close enough to read the street.
  ///
  /// Used everywhere the map is asked to look at somebody: tapping a friend's
  /// pin, tapping your own, and pressing "find me". Those all answer the
  /// question "where exactly", and [_initialZoom] answers "which town" — you
  /// could see the pin move to the centre and learn nothing you did not
  /// already know.
  ///
  /// Never zooms *out*: somebody already pushed in closer than [_focusZoom]
  /// asked for that, and yanking them back would undo it on every tap.
  void _focusOn(LatLng point) {
    _moveCamera(point, math.max(_currentZoom ?? _focusZoom, _focusZoom));
    _centered = true;
  }

  /// The camera's zoom, or null when there is no camera to ask.
  ///
  /// [MapController.camera] throws outright until the map has been laid out
  /// once, and everything here that points the camera somewhere — a fix
  /// arriving, a tap in the friends sheet, the refresh timer — can land in
  /// that window. Reading it through here turns a crash into a first
  /// placement, which is what the map does on its first fix anyway.
  double? get _currentZoom {
    try {
      return _map.camera.zoom;
    } catch (_) {
      return null;
    }
  }

  LatLng? get _currentCentre {
    try {
      return _map.camera.center;
    } catch (_) {
      return null;
    }
  }

  /// Point the camera at a friend picked from the list, and select them.
  ///
  /// Selecting as well as moving is the point: the card that names who you are
  /// looking at is the same card a tap on their pin raises, so arriving from
  /// the list lands you in the state you would have been in had you found them
  /// yourself.
  void _focusOnPeer(String peerId) {
    final entry = ref.read(sharedMapLocationsProvider)[peerId];
    if (entry == null || !mounted) return;
    setState(() {
      _mineSelected = false;
      _selectedId = peerId;
    });
    _focusOn(LatLng(entry.location.latitude, entry.location.longitude));
  }

  /// Glide the camera to [target]. Falls back to a plain move for the first
  /// placement, where there is no "from" to animate out of.
  void _moveCamera(LatLng target, double zoom) {
    final current = _centered ? _currentCentre : null;
    if (current == null) {
      try {
        _map.move(target, zoom);
      } catch (_) {
        // Not laid out yet. The map places itself on the next fix, and the
        // 90-second refresh guarantees there is one.
      }
      return;
    }
    _cameraFrom = current;
    _cameraTo = target;
    _zoomFrom = _currentZoom ?? zoom;
    _zoomTo = zoom;
    _camera
      ..reset()
      ..forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_watching == visible) return;
    _watching = visible;
    AppLifecycle.instance.isWatchingMap = visible;
    _refresh?.cancel();
    if (visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _watching) {
          unawaited(_locate());
        }
      });
      _refresh = Timer.periodic(const Duration(seconds: 90), (_) {
        if (mounted && _watching) {
          unawaited(_locate());
        }
      });
    }
  }

  Future<void> _locate({bool recenter = false}) async {
    if (!ref.read(privacySettingsProvider).shareMapLocation) {
      if (mounted) {
        setState(() {
          _me = null;
          _failure = null;
          _mineSelected = false;
        });
      }
      return;
    }
    if (_locating) return;
    setState(() => _locating = true);
    final (fix, failure) = await ref.read(mapLocationReaderProvider)();
    if (!mounted) return;
    setState(() {
      _locating = false;
      _failure = failure;
      if (fix != null) _me = fix;
    });
    if (fix != null) {
      unawaited(ref.read(mapPresenceControllerProvider.notifier).pokeNow());
    }
    if (fix != null && (recenter || !_centered)) {
      final point = LatLng(fix.latitude, fix.longitude);
      _focusOn(point);
      _scheduleAddressLookup(point);
    }
  }

  @override
  void dispose() {
    AppLifecycle.instance.isWatchingMap = false;
    _refresh?.cancel();
    _addressDebounce?.cancel();
    _camera
      ..removeListener(_tickCamera)
      ..dispose();
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final peers = ref.watch(knownPeersControllerProvider);
    final photos = ref.watch(peerAvatarsControllerProvider);
    final shared = ref.watch(sharedMapLocationsProvider);
    final mapSharing =
        ref.watch(privacySettingsProvider.select((s) => s.shareMapLocation));
    // Switching sharing off drops the fix, not just its pin. Keeping it would
    // mean switching back on re-displays where you were before — a position
    // from a time you had asked not to be located.
    ref.listen(privacySettingsProvider.select((s) => s.shareMapLocation),
        (_, sharing) {
      if (!sharing && _me != null && mounted) {
        setState(() {
          _me = null;
          _failure = null;
          _mineSelected = false;
        });
      }
    });
    // Somebody tapped a name in the sheet that floats over this screen. The
    // sheet is gone by the time this fires; the camera is ours to move.
    ref.listen(mapFocusRequestProvider, (_, request) {
      if (request != null) _focusOnPeer(request.peerId);
    });
    final nickname = ref.watch(nicknameControllerProvider);
    final ownPhoto = ref.watch(avatarProvider);
    final nodes = <_Node>[
      for (final entry in shared.entries)
        // A live pin outlives its own expiry — see [SharedMapLocation.live].
        // A position shared into a conversation does not: that one carried a
        // window its sender chose, and honouring it is the difference between
        // "here I am" and "here is where I live".
        if ((entry.value.live || !entry.value.location.expired) &&
            peers[entry.key] != null)
          _Node(
            id: entry.key,
            name: peers[entry.key]!.displayName,
            point: LatLng(
              entry.value.location.latitude,
              entry.value.location.longitude,
            ),
            sentAt: entry.value.sentAt,
            photo: photos[entry.key],
          ),
    ]..sort((a, b) => b.sentAt.compareTo(a.sentAt));
    if (nodes.length > 80) nodes.removeRange(80, nodes.length);

    _Node? selected;
    for (final node in nodes) {
      if (node.id == _selectedId) selected = node;
    }
    final mePoint = !mapSharing || _me == null
        ? null
        : LatLng(_me!.latitude, _me!.longitude);
    final testTileProvider =
        widget.tileProvider ?? ref.watch(mapTileProviderProvider);
    final mapLayer = ref.watch(mapLayerControllerProvider);
    final overlayBottom = MediaQuery.paddingOf(context).bottom + 104;
    final profileTop = MediaQuery.paddingOf(context).top + 86;
    final selectedNode = _mineSelected && mePoint != null
        ? _Node(
            id: 'me',
            name: nickname,
            point: mePoint,
            sentAt: DateTime.now(),
            photo: ownPhoto,
          )
        : selected;
    final selectedDetail = _mineSelected && mePoint != null
        ? t.mapYouOnMap
        : selected == null
            ? null
            : '${_distanceText(t, mePoint, selected.point)}'
                ' \u00B7 ${_ageText(t, selected.sentAt)}';

    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      body: Stack(
        children: [
          Positioned.fill(
            child: _buildMap(
              nodes,
              mePoint,
              nickname,
              ownPhoto,
              testTileProvider,
              mapLayer,
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: FloatingGlass(
                  borderRadius: 24,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      const _RoundIcon(icon: Icons.public_rounded),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              t.mapTitle,
                              style: TextStyle(
                                color: AppColors.textOnGlass,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_centerAddress != null)
                              Text(
                                _centerAddress!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.textOnGlassDim,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => showMapFriendsSheet(context),
                        tooltip: t.mapFriendsTitle,
                        icon: Icon(
                          Icons.group_add_rounded,
                          color: AppColors.brandPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_failure != null)
            Positioned(
              top: profileTop +
                  (selectedNode == null || selectedDetail == null ? 0 : 82),
              left: 24,
              right: 24,
              child: _StatusPill(text: _failureText(t, _failure!)),
            ),
          Positioned(
            right: 16,
            bottom: overlayBottom,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_rotated) ...[
                  _MapActionButton(
                    icon: Icons.explore_rounded,
                    tooltip: t.mapNorthUp,
                    onTap: () {
                      _map.rotate(0);
                      setState(() => _rotated = false);
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                _MapActionButton(
                  icon: Icons.layers_rounded,
                  tooltip: t.mapLayerTitle,
                  onTap: () => showMapLayerSheet(context),
                ),
                const SizedBox(height: 12),
                _MapActionButton(
                  icon: Icons.person_search_rounded,
                  tooltip: t.mapFriendsTitle,
                  // Used to jump to the address book, which left the map
                  // entirely to answer a question about it. The people worth
                  // finding from here are the handful already on the map, and
                  // the sheet that lists them can now take the camera to one.
                  onTap: () => showMapFriendsSheet(context),
                ),
                const SizedBox(height: 12),
                _MapActionButton(
                  icon: Icons.my_location_rounded,
                  tooltip: t.mapCenterMe,
                  onTap: _locating ? null : _centerOnMe,
                  loading: _locating,
                ),
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: profileTop,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -0.18),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: selectedNode == null || selectedDetail == null
                      ? const SizedBox.shrink(key: ValueKey('map-card-empty'))
                      : _PersonCard(
                          key: ValueKey(
                            _mineSelected ? 'map-card-me' : selectedNode.id,
                          ),
                          node: selectedNode,
                          detail: selectedDetail,
                          action: t.mapOpenProfile,
                          mine: _mineSelected,
                          onTap: () {
                            if (_mineSelected) {
                              context.go('/profile');
                              return;
                            }
                            context.push(
                              '/person/${Uri.encodeComponent(selectedNode.id)}'
                              '?name=${Uri.encodeQueryComponent(selectedNode.name)}',
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "Find me": move the camera *and* say which pin is the answer.
  ///
  /// Selecting is half the job. Standing next to somebody, the camera arrived
  /// on a pin drawn underneath theirs, with their card on screen — so the
  /// button looked like it had centred on the wrong person. Selecting raises
  /// the pin above the crowd and puts your own card up; tapping the map
  /// afterwards clears it and hands both back.
  Future<void> _centerOnMe() async {
    setState(() {
      _mineSelected = true;
      _selectedId = null;
    });
    await _locate(recenter: true);
  }

  /// Fold pins that would be drawn on top of each other into one.
  ///
  /// The threshold is the pin itself: two people closer together than a pin is
  /// wide cannot both be seen, and — worse — only the upper one can be tapped.
  /// Expressed in pixels and converted to metres at the current zoom, so
  /// pulling back gathers people up and pushing in lets them go again, which is
  /// the behaviour every map has and the reason zooming in feels like it does
  /// something.
  List<List<_Node>> _cluster(List<_Node> nodes) {
    if (nodes.length < 2) {
      return [for (final node in nodes) [node]];
    }
    final latitude = _currentCentre?.latitude ?? nodes.first.point.latitude;
    final metres = metresPerPixel(latitude, _markerZoom);
    return clusterByDistance(
      nodes,
      pointOf: (node) => node.point,
      thresholdMetres: 52 * _markerScale * metres,
    );
  }

  static LatLng _centroid(List<_Node> nodes) {
    var latitude = 0.0;
    var longitude = 0.0;
    for (final node in nodes) {
      latitude += node.point.latitude;
      longitude += node.point.longitude;
    }
    return LatLng(latitude / nodes.length, longitude / nodes.length);
  }

  void _openCluster(List<_Node> group) {
    final t = AppLocalizations.of(context);
    final mePoint = _me == null ? null : LatLng(_me!.latitude, _me!.longitude);
    showMapClusterSheet(
      context,
      [
        for (final node in group)
          MapClusterMember(
            peerId: node.id,
            name: node.name,
            detail: '${_distanceText(t, mePoint, node.point)}'
                ' · ${_ageText(t, node.sentAt)}',
          ),
      ],
    );
  }

  Marker _ownMarker(LatLng me, String nickname, Uint8List? ownPhoto) => Marker(
        point: me,
        width: _markerBox,
        height: _markerBox,
        child: _MapAvatar(
          key: const ValueKey('map-own-marker'),
          seed: 'me',
          name: nickname,
          photo: ownPhoto,
          mine: true,
          selected: _mineSelected,
          scale: _markerScale,
          onTap: () {
            setState(() {
              _mineSelected = true;
              _selectedId = null;
            });
            _focusOn(me);
          },
        ),
      );

  Widget _buildMap(
    List<_Node> nodes,
    LatLng? mePoint,
    String nickname,
    Uint8List? ownPhoto,
    TileProvider? tileProvider,
    MapLayer layer,
  ) {
    // A parameter does not stay promoted inside a closure, and the marker's
    // onTap is one — hence the local copy the null check can promote.
    final LatLng? me = mePoint;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _fallbackCenter,
        initialZoom: _initialZoom,
        minZoom: 3,
        maxZoom: 18,
        backgroundColor: const Color(0xFF101A22),
        // Rotation is on now. It was excluded because a map that turns under a
        // thumb and cannot be turned back is worse than one that never turns —
        // so the way back is the point: the compass appears the moment north
        // stops being up, and puts it back.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all,
        ),
        onMapReady: () => _scheduleAddressLookup(_fallbackCenter),
        onTap: (_, __) => setState(() {
          _selectedId = null;
          _mineSelected = false;
        }),
        onMapEvent: (event) {
          // Resize the pins in quarter-zoom steps. Finer than the eye follows,
          // coarse enough that a pinch does not rebuild every marker on every
          // frame of the gesture.
          if ((event.camera.zoom - _markerZoom).abs() >= 0.25) {
            setState(() => _markerZoom = event.camera.zoom);
          }
          // Rounded, so a fingertip's worth of wobble does not raise the
          // compass on a map nobody meant to turn.
          final rotated = event.camera.rotation.abs() > 1;
          if (rotated != _rotated) setState(() => _rotated = rotated);
          if (event is MapEventMoveStart ||
              event is MapEventFlingAnimationStart ||
              event is MapEventDoubleTapZoomStart) {
            _addressDebounce?.cancel();
            return;
          }
          if (event is MapEventMoveEnd ||
              event is MapEventFlingAnimationEnd ||
              event is MapEventFlingAnimationNotStarted ||
              event is MapEventDoubleTapZoomEnd) {
            _scheduleAddressLookup(event.camera.center);
          }
        },
      ),
      children: [
        // A dark, label-free basemap, drawn at full strength.
        //
        // This used to be the standard OpenStreetMap style — a light map with
        // every street name printed into the raster — held down to 18% opacity
        // under a 58% black sheet and a brand tint. Three ways of fighting the
        // tiles instead of asking for different ones, which is why the map read
        // as "very dark" and "broken": what showed through was a ghost of a
        // light map, and the labels were baked into the image so no amount of
        // dimming could remove them.
        //
        // CARTO's dark_nolabels is the same OpenStreetMap data rendered dark
        // with no text at all, which is exactly what this screen wants: the
        // street and city are read out in the panel above, where they can be
        // localised and where they do not fight the avatars for space. It also
        // drops two full-screen overlay passes per frame.
        RepaintBoundary(
          // Keyed on the style, so switching swaps the layer outright instead
          // of asking one TileLayer to change its own URL — which leaves the
          // previous style's squares on screen until each is replaced.
          child: TileLayer(
            key: ValueKey('map-tiles-${layer.id}'),
            urlTemplate: layer.urlTemplate,
            subdomains: layer.subdomains,
            retinaMode:
                layer.supportsRetina && RetinaMode.isHighDensity(context),
            userAgentPackageName: 'com.cubechat.cubechat',
            tileProvider: tileProvider,
            maxNativeZoom: layer.maxNativeZoom,
            keepBuffer: 1,
            panBuffer: 0,
            tileUpdateTransformer: TileUpdateTransformers.throttle(
              const Duration(milliseconds: 180),
            ),
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
          ),
        ),
        // Static, deliberately. These lines used to breathe on a five-second
        // pulse, which meant repainting every gradient stroke on the map on
        // every frame for as long as the screen was open — the most expensive
        // thing here, spent on an effect nobody was looking at while trying to
        // find someone.
        if (nodes.length > 1 && nodes.length <= 16)
          RepaintBoundary(
            child: PolylineLayer(
              polylines: _lines(nodes, mePoint),
            ),
          ),
        MarkerLayer(
          markers: [
            // Own pin first, under everybody else's — until it is the selected
            // one, when it goes last and therefore on top.
            //
            // A marker layer paints in list order, so standing next to a
            // friend used to bury you under them: pressing "find me" moved the
            // camera onto a pin you could not see, which read as the button
            // doing nothing. Selecting is now what decides the order, and a
            // tap on empty map clears the selection and hands the top back.
            if (me != null && !_mineSelected) _ownMarker(me, nickname, ownPhoto),
            for (final group in _cluster(nodes))
              if (group.length == 1)
                Marker(
                  point: group.single.point,
                  width: _markerBox,
                  height: _markerBox,
                  child: _MapAvatar(
                    seed: group.single.id,
                    name: group.single.name,
                    photo: group.single.photo,
                    selected: group.single.id == _selectedId,
                    scale: _markerScale,
                    onTap: () {
                      setState(() {
                        _selectedId = group.single.id;
                        _mineSelected = false;
                      });
                      _focusOn(group.single.point);
                    },
                  ),
                )
              else
                Marker(
                  point: _centroid(group),
                  width: _markerBox,
                  height: _markerBox,
                  child: _MapCluster(
                    nodes: group,
                    scale: _markerScale,
                    onTap: () => _openCluster(group),
                  ),
                ),
            if (me != null && _mineSelected) _ownMarker(me, nickname, ownPhoto),
          ],
        ),
        // Required by each style's licence, and honest about who is being
        // asked for the squares being looked at — which changes with the
        // style, so the credit has to as well.
        RichAttributionWidget(
          attributions: [
            for (final (name, url) in layer.attributions)
              TextSourceAttribution(
                name,
                onTap: () => launchUrl(Uri.parse(url)),
              ),
          ],
        ),
      ],
    );
  }

  String _failureText(AppLocalizations t, LocationFailure failure) =>
      switch (failure) {
        LocationFailure.denied => t.mapLocationDenied,
        LocationFailure.serviceOff => t.mapLocationServiceOff,
        LocationFailure.unavailable => t.mapLocationUnavailable,
      };

  String _distanceText(AppLocalizations t, LatLng? from, LatLng to) {
    if (from == null) return t.mapDistanceUnknown;
    final metres = _distance.as(LengthUnit.Meter, from, to).round();
    if (metres < 1000) return t.mapDistanceMetres(metres);
    return t.mapDistanceKilometres(
      (metres / 1000).toStringAsFixed(metres < 10000 ? 1 : 0),
    );
  }

  String _ageText(AppLocalizations t, DateTime at) {
    final minutes = math.max(0, DateTime.now().difference(at).inMinutes);
    if (minutes < 1) return t.mapUpdatedNow;
    if (minutes < 60) return t.mapUpdatedMinutes(minutes);
    return t.mapUpdatedHours(math.max(1, minutes ~/ 60));
  }

  void _scheduleAddressLookup(LatLng point) {
    // Widget tests inject a tile provider and have no native geocoder.
    if (widget.tileProvider != null) return;
    final cell = '${point.latitude.toStringAsFixed(3)}:'
        '${point.longitude.toStringAsFixed(3)}';
    if (cell == _addressCell) return;
    _addressDebounce?.cancel();
    _addressDebounce = Timer(const Duration(milliseconds: 650), () {
      if (_addressReading) {
        _queuedAddressPoint = point;
        _queuedAddressCell = cell;
        return;
      }
      unawaited(_readAddress(point, cell));
    });
  }

  Future<void> _readAddress(LatLng point, String cell) async {
    final request = ++_addressRequest;
    _addressReading = true;
    final locale = Localizations.localeOf(context);
    try {
      final address = await ref.read(mapAddressReaderProvider)(
        point.latitude,
        point.longitude,
        locale,
      );
      if (mounted && request == _addressRequest && address != null) {
        setState(() {
          _addressCell = cell;
          _centerAddress = address;
        });
      }
    } finally {
      _addressReading = false;
      final queuedPoint = _queuedAddressPoint;
      final queuedCell = _queuedAddressCell;
      _queuedAddressPoint = null;
      _queuedAddressCell = null;
      if (mounted && queuedPoint != null && queuedCell != null) {
        _addressDebounce?.cancel();
        _addressDebounce = Timer(const Duration(milliseconds: 450), () {
          if (!_addressReading) {
            unawaited(_readAddress(queuedPoint, queuedCell));
          }
        });
      }
    }
  }

  List<Polyline> _lines(
    List<_Node> nodes,
    LatLng? me,
  ) {
    // Rounded to ~11 m: a fix jitters by a few metres while standing still, and
    // recomputing an O(n²) graph because somebody's GPS breathed is work with
    // no visible result.
    String cell(LatLng p) => '${p.latitude.toStringAsFixed(4)},'
        '${p.longitude.toStringAsFixed(4)}';
    final key = [
      if (me != null) 'me:${cell(me)}',
      for (final n in nodes) '${n.id}:${cell(n.point)}',
    ].join('|');
    final cached = _cachedLines;
    if (cached != null && key == _cachedLinesKey) return cached;

    final built = _buildLines(nodes, me);
    _cachedLines = built;
    _cachedLinesKey = key;
    return built;
  }

  List<Polyline> _buildLines(
    List<_Node> nodes,
    LatLng? me,
  ) {
    final points = [if (me != null) me, ...nodes.map((n) => n.point)];
    final used = <String>{};
    final result = <Polyline>[];
    for (var i = 0; i < points.length; i++) {
      final nearest = <({int i, double metres})>[
        for (var j = 0; j < points.length; j++)
          if (i != j)
            (
              i: j,
              metres: _distance.as(LengthUnit.Meter, points[i], points[j]),
            ),
      ]..sort((a, b) => a.metres.compareTo(b.metres));
      for (final other in nearest.take(2)) {
        if (other.metres > 50000) continue;
        final a = math.min(i, other.i);
        final b = math.max(i, other.i);
        if (!used.add('$a:$b')) continue;
        final path = [points[a], points[b]];
        result
          ..add(
            Polyline(
              points: path,
              strokeWidth: 8,
              color: AppColors.brandPrimary.withValues(alpha: 0.10),
            ),
          )
          ..add(
            Polyline(
              points: path,
              strokeWidth: 1.5,
              gradientColors: [
                AppColors.brandPrimary.withValues(alpha: 0.34),
                AppColors.brandSecondary.withValues(alpha: 0.58),
              ],
            ),
          );
      }
    }
    return result;
  }
}

class _Node {
  const _Node({
    required this.id,
    required this.name,
    required this.point,
    required this.sentAt,
    this.photo,
  });

  final String id;
  final String name;
  final LatLng point;
  final DateTime sentAt;
  final Uint8List? photo;
}

class _MapAvatar extends StatelessWidget {
  const _MapAvatar({
    super.key,
    required this.seed,
    required this.name,
    this.photo,
    this.selected = false,
    this.mine = false,
    this.scale = 1,
    this.onTap,
  });

  final String seed;
  final String name;
  final Uint8List? photo;
  final bool selected;
  final bool mine;

  /// How large this pin is drawn relative to its close-up size — see
  /// [_PeopleMapScreenState._markerScale].
  final double scale;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final size = (selected ? 58.0 : 52.0) * scale;
    // Each avatar carries two shadows, one of them a 22px glow. Without a
    // boundary every one of them re-rasterises whenever anything else on the
    // map changes — panning, a beacon landing, the camera gliding — which is
    // most of what made dragging the map feel like it was catching.
    return RepaintBoundary(
      child: GestureDetector(
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: size + 10,
            height: size + 10,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.pane(0.84),
              border: Border.all(
                color: mine
                    ? AppColors.ink(0.85)
                    : AppColors.brandPrimary.withValues(
                        alpha: selected ? 0.95 : 0.62,
                      ),
                width: selected ? 2.2 : 1.3,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.brandPrimary.withValues(
                    alpha: selected ? 0.46 : 0.25,
                  ),
                  blurRadius: selected ? 22 : 14,
                  spreadRadius: selected ? 2 : 0,
                ),
                const BoxShadow(
                  color: Colors.black54,
                  blurRadius: 12,
                  offset: Offset(0, 7),
                ),
              ],
            ),
            child: IdentityAvatar(
              seed: seed,
              label: name,
              imageBytes: photo,
              size: size,
              online: mine,
            ),
          ),
        ),
      ),
    );
  }
}

/// Several people standing close enough to be one pin.
///
/// Four faces at most, in a two-by-two: enough to recognise who is in there
/// without any of them becoming a dot. Beyond four the last slot becomes the
/// count, because "+6" says what six more faces the size of a full stop cannot.
class _MapCluster extends StatelessWidget {
  const _MapCluster({
    required this.nodes,
    required this.scale,
    required this.onTap,
  });

  final List<_Node> nodes;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final size = 58.0 * scale;
    final shown = nodes.length > 4 ? nodes.take(3).toList() : nodes.take(4).toList();
    final rest = nodes.length - shown.length;
    final cell = (size - 10) / 2;

    return RepaintBoundary(
      child: GestureDetector(
        onTap: onTap,
        child: Center(
          child: Container(
            width: size + 10,
            height: size + 10,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.pane(0.88),
              border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.72),
                width: 1.6,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.brandPrimary.withValues(alpha: 0.28),
                  blurRadius: 16,
                ),
                const BoxShadow(
                  color: Colors.black54,
                  blurRadius: 12,
                  offset: Offset(0, 7),
                ),
              ],
            ),
            child: ClipOval(
              child: Wrap(
                spacing: 1,
                runSpacing: 1,
                alignment: WrapAlignment.center,
                children: [
                  for (final node in shown)
                    SizedBox(
                      width: cell,
                      height: cell,
                      child: IdentityAvatar(
                        seed: node.id,
                        label: node.name,
                        imageBytes: node.photo,
                        size: cell,
                      ),
                    ),
                  if (rest > 0)
                    Container(
                      width: cell,
                      height: cell,
                      alignment: Alignment.center,
                      color: AppColors.brandPrimary.withValues(alpha: 0.22),
                      child: FittedBox(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Text(
                            '+$rest',
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.brandPrimary.withValues(alpha: 0.14),
        ),
        child: Icon(icon, color: AppColors.brandPrimary, size: 21),
      );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: FloatingGlass(
          blur: false,
          borderRadius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.location_off_outlined,
                color: AppColors.warning,
                size: 18,
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({
    super.key,
    required this.node,
    required this.detail,
    required this.action,
    required this.mine,
    required this.onTap,
  });

  final _Node node;
  final String detail;
  final String action;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FloatingGlass(
        borderRadius: 24,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            IdentityAvatar(
              seed: node.id,
              label: node.name,
              imageBytes: node.photo,
              size: 48,
              online: mine,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  action,
                  style: TextStyle(
                    color: AppColors.brandPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.brandPrimary,
                ),
              ],
            ),
          ],
        ),
      );
}

class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) => FloatingGlass(
        borderRadius: 22,
        onTap: onTap,
        padding: const EdgeInsets.all(12),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Center(
              child: loading
                  ? CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: AppColors.brandPrimary,
                    )
                  : Icon(
                      icon,
                      color: AppColors.brandPrimary,
                      size: 22,
                    ),
            ),
          ),
        ),
      );
}



