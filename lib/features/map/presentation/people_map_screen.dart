import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
// Narrowed with `show`: both packages export their own LatLng, which would
// collide with latlong2's — the one this screen and the whole map layer speak.
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart'
    show GoogleMapsFlutterAndroid;
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    show GoogleMapsFlutterPlatform;
import 'package:latlong2/latlong.dart';

import '../../../core/identity/avatar_controller.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/util/app_lifecycle.dart';
import '../../../core/util/location_service.dart';
import '../../../core/util/ui_activity.dart';
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
import '../../../core/util/debug_log.dart';

// Kept as a test seam. Older widget tests pass a flutter_map TileProvider here;
// the production screen ignores it and mounts native Google Maps instead.
final mapTileProviderProvider = Provider<Object?>((ref) => null);

// Google Maps owns its own tile/network cache. The old flutter_map cache init is
// intentionally a no-op now, but main.dart still calls it during startup.
Future<void> initMapTileCache() async {}

typedef MapLocationReader = Future<(LocationFix?, LocationFailure?)> Function();
typedef MapAddressReader = Future<String?> Function(
  double latitude,
  double longitude,
  Locale locale,
);

final mapLocationReaderProvider = Provider<MapLocationReader>(
  (ref) => const LocationService().current,
);
final mapAddressReaderProvider = Provider<MapAddressReader>(
  (ref) => const MapAddressService().read,
);

class PeopleMapScreen extends ConsumerStatefulWidget {
  const PeopleMapScreen({
    super.key,
    this.tileProvider,
    this.nativeMapEnabled = true,
  });

  final Object? tileProvider;
  final bool nativeMapEnabled;

  @override
  ConsumerState<PeopleMapScreen> createState() => _PeopleMapScreenState();
}

class _PeopleMapScreenState extends ConsumerState<PeopleMapScreen>
    with WidgetsBindingObserver {
  static const _fallbackCenter = LatLng(50.4501, 30.5234);
  static const _initialZoom = 15.0;
  static const _focusZoom = 17.2;
  static const _markerTapZoom = 17.0;

  final _distance = const Distance();

  gm.GoogleMapController? _googleMap;
  LocationFix? _me;
  LocationFailure? _failure;
  Timer? _refresh;
  Timer? _addressDebounce;
  bool _addressReading = false;
  bool _locating = false;
  bool _watching = false;
  bool _centered = false;
  bool _mineSelected = false;
  bool _rotated = false;

  /// True once the camera is leaning, which is the only angle from which 3D
  /// buildings can be seen — and therefore the only one worth drawing them at.
  bool _tilted = false;
  String? _selectedId;
  String? _centerAddress;
  String? _addressCell;
  LatLng? _queuedAddressPoint;
  String? _queuedAddressCell;
  int _addressRequest = 0;
  LatLng _cameraCentre = _fallbackCenter;
  double _markerZoom = _initialZoom;

  /// The zoom the clusters were last computed at, in whole levels.
  double _clusterZoom = _initialZoom.roundToDouble();
  double _cameraClusterZoom = _initialZoom.roundToDouble();
  bool _cameraRotated = false;
  bool _cameraTilted = false;

  /// Bumped whenever a marker bitmap finishes rendering, so the memoised
  /// marker set knows to rebuild with the real picture in place of the
  /// placeholder pin.
  int _markerIconGeneration = 0;

  Set<gm.Marker>? _cachedMarkers;
  String? _cachedMarkersKey;
  gm.CameraPosition? _pendingCamera;
  List<gm.Polyline>? _cachedLines;
  String? _cachedLinesKey;
  final _markerIcons = <String, gm.BitmapDescriptor>{};
  final _markerIconsInFlight = <String>{};

  bool get _usesNativeMap =>
      widget.nativeMapEnabled &&
      widget.tileProvider == null &&
      ref.read(mapTileProviderProvider) == null;

  double get _markerScale {
    final zoom = _markerZoom;
    if (zoom >= 14) return 1;
    if (zoom >= 11) return 0.86;
    if (zoom >= 8) return 0.72;
    return 0.58;
  }

  double get _markerBox => 72 * _markerScale;

  @override
  void initState() {
    super.initState();
    // Texture layer, not hybrid composition — stated rather than left to the
    // default, because it was the other way round for one build and the
    // reasoning is worth keeping.
    //
    // Hybrid composition was turned on to stop the map coming back black, and
    // it did: a texture-layer platform view goes black under a BackdropFilter,
    // and every panel on this screen was glass sampling what was behind it. It
    // also made the map crawl, because hybrid composition synchronises the
    // native view with the Flutter scene on every frame.
    //
    // The blur is what was actually wrong. Those panes now sit on the map
    // without sampling it (see `blur: false` below), which removes the black
    // *and* the most expensive thing in the frame — so the fast path is
    // affordable again.
    final platform = GoogleMapsFlutterPlatform.instance;
    if (platform is GoogleMapsFlutterAndroid) {
      platform.useAndroidViewSurface = false;
    }
    WidgetsBinding.instance.addObserver(this);
  }

  /// Wake the map's texture after a spell in the background.
  ///
  /// The fast path above renders the native map into a texture layer rather
  /// than a view synchronised with the Flutter scene, which is what makes it
  /// affordable — and also what makes it fragile across a trip to the
  /// background. Android is free to drop the texture behind a stopped app, and
  /// nothing asks for a new one on the way back: the Flutter side still holds a
  /// live controller and a valid camera, so it has no reason to think anything
  /// is wrong. What the user sees is the map drawing fine, going away, and
  /// coming back as an empty pane with the Google logo in the corner.
  ///
  /// Two camera moves that cancel out are enough to force a fresh frame. A
  /// pixel each way is below anything anyone can see and leaves the camera
  /// exactly where it was, which matters — a resume must not move somebody's
  /// map out from under them.
  ///
  /// Only when this screen is the one being looked at. The map tab keeps its
  /// state while other tabs are on screen, and nudging a map nobody is
  /// watching would spend a frame to fix nothing.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_watching) return;
    final map = _googleMap;
    if (map == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_watching) return;
      try {
        await map.moveCamera(gm.CameraUpdate.scrollBy(1, 0));
        await map.moveCamera(gm.CameraUpdate.scrollBy(-1, 0));
      } catch (e) {
        // A controller that died with the surface is exactly the case this is
        // for, and there is nothing further to do about it here.
        DebugLog.instance.log('MAP', 'resume nudge failed: $e');
      }
    });
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
        if (mounted && _watching) unawaited(_locate());
      });
      _refresh = Timer.periodic(const Duration(seconds: 90), (_) {
        if (mounted && _watching) unawaited(_locate());
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
    // The position the live-map subscription is already receiving, when it is
    // recent. This screen used to ask for its own fix every ninety seconds
    // beside the beacon's own forty-five — two radios' worth of work for one
    // pin, on the one screen where the phone is already busy drawing a map.
    final shared = ref.read(lastLocationFixProvider)?.fresh;
    if (shared != null) {
      setState(() {
        _failure = null;
        _me = shared;
      });
      if (recenter || !_centered) {
        final point = LatLng(shared.latitude, shared.longitude);
        _focusOn(point);
        _scheduleAddressLookup(point);
      }
      return;
    }
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

  void _focusOnPeer(String peerId) {
    final entry = ref.read(sharedMapLocationsProvider)[peerId];
    if (entry == null || !mounted) return;
    setState(() {
      _mineSelected = false;
      _selectedId = peerId;
    });
    _focusOn(LatLng(entry.location.latitude, entry.location.longitude));
  }

  void _focusOn(LatLng point, {double zoom = _focusZoom}) {
    _moveCamera(point, math.max(_markerZoom, zoom));
    _centered = true;
  }

  Future<void> _moveCamera(LatLng target, double zoom) async {
    _cameraCentre = target;
    final update = gm.CameraUpdate.newCameraPosition(
      gm.CameraPosition(target: _gm(target), zoom: zoom),
    );
    final controller = _googleMap;
    if (controller == null) {
      _pendingCamera = gm.CameraPosition(target: _gm(target), zoom: zoom);
      return;
    }
    try {
      await controller.animateCamera(update);
    } catch (_) {
      try {
        await controller.moveCamera(update);
      } catch (_) {
        // The platform view can briefly be unavailable during route changes.
      }
    }
  }

  Future<void> _centerOnMe() async {
    await _locate(recenter: true);
    final me = _me;
    if (me == null) return;
    setState(() {
      _mineSelected = true;
      _selectedId = null;
    });
    _focusOn(LatLng(me.latitude, me.longitude));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLifecycle.instance.isWatchingMap = false;
    _refresh?.cancel();
    _addressDebounce?.cancel();
    _googleMap?.dispose();
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
    ref.listen(mapFocusRequestProvider, (_, request) {
      if (request != null) _focusOnPeer(request.peerId);
    });

    final nickname = ref.watch(nicknameControllerProvider);
    final ownPhoto = ref.watch(avatarProvider);
    final nodes = <_Node>[
      for (final entry in shared.entries)
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
    final mapLayer = ref.watch(mapLayerControllerProvider);
    final testMapProvider =
        widget.tileProvider ?? ref.watch(mapTileProviderProvider);
    final nativeMap = widget.nativeMapEnabled && testMapProvider == null;
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
                ' · ${_ageText(t, selected.sentAt)}';

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
              mapLayer,
              nativeMap: nativeMap,
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
                  // No blur over the map. A BackdropFilter snapshots the
                  // layer below and runs a gaussian over it every frame, and
                  // below this one is a native map view — the most expensive
                  // backdrop there is to sample, and the one that renders
                  // black when a texture-layer platform view is sampled at
                  // all. The pane keeps its fill, border and shadows.
                  blur: false,
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
                    onTap: _resetBearing,
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

  Widget _buildMap(
    List<_Node> nodes,
    LatLng? me,
    String nickname,
    Uint8List? ownPhoto,
    MapLayer layer, {
    required bool nativeMap,
  }) {
    if (!nativeMap) {
      return _buildFallbackMap(nodes, me, nickname, ownPhoto);
    }

    final target =
        me ?? (nodes.isNotEmpty ? nodes.first.point : _fallbackCenter);
    return gm.GoogleMap(
      key: ValueKey('google-map-${layer.id}'),
      initialCameraPosition: gm.CameraPosition(
        target: _gm(target),
        zoom: _initialZoom,
      ),
      style: layer == MapLayer.dark ? _googleDarkStyle : null,
      mapType: _googleMapType(layer),
      minMaxZoomPreference: const gm.MinMaxZoomPreference(4, 20),
      compassEnabled: false,
      mapToolbarEnabled: false,
      myLocationButtonEnabled: false,
      myLocationEnabled: false,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: true,
      zoomControlsEnabled: false,
      // Only once somebody has actually tilted the camera. Extruded buildings
      // are the map's most expensive layer and they are invisible from
      // straight above, so drawing them flat is heat spent on nothing — which
      // is what the map tab was doing on every phone that opened it.
      buildingsEnabled: _tilted,
      trafficEnabled: false,
      indoorViewEnabled: false,
      // Symmetric, and that is the whole point of it.
      //
      // Map padding does two things at once: it keeps Google's own furniture
      // (the logo, bottom left) clear of the chrome floating over the map, and
      // it decides where the *camera target* lands. Only the asymmetry does the
      // second — a box with 184 above and 160 below puts the target twelve
      // points low, and 84 on the right put it forty-two points left. So
      // focusing on somebody dropped them noticeably off-centre, which is what
      // "put profiles dead centre" was about.
      //
      // Equal top and bottom means the target is the middle of the screen
      // whatever the number is, and the number is chosen for the logo: enough
      // to lift it clear of the floating nav bar. Nothing needs padding on the
      // right — the controls there are ours and they float over the map rather
      // than belonging to it.
      padding: EdgeInsets.symmetric(
        vertical: MediaQuery.paddingOf(context).bottom + 160,
      ),
      markers: _googleMarkers(nodes, me, nickname, ownPhoto),
      polylines: _googleLines(nodes, me).toSet(),
      // Without this the map cannot be panned or zoomed at all, and the reason
      // is this app rather than the plugin: every page is wrapped in a
      // drag-anywhere back gesture (see EdgeBackGesture), so Flutter's arena
      // claims the horizontal drag before the platform view ever sees it, and
      // a native map that never receives a drag is a picture. Claiming the
      // gesture eagerly hands everything inside the map's own bounds to the
      // map — which also means no back-swipe over it, and that is the right
      // trade: this screen is a tab, there is nothing behind it to swipe to.
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onMapCreated: (controller) {
        _googleMap = controller;
        final pending = _pendingCamera;
        _pendingCamera = null;
        if (pending != null) {
          unawaited(
            controller.moveCamera(
              gm.CameraUpdate.newCameraPosition(pending),
            ),
          );
        }
      },
      onTap: (_) {
        setState(() {
          _selectedId = null;
          _mineSelected = false;
        });
      },
      onCameraMove: (position) {
        // Tell the app the interface is moving.
        //
        // This is the same flag a scrolling list raises, and the navigation
        // bar reads it to drop its backdrop filter while the motion lasts. A
        // moving map never raised it — there is no ScrollNotification behind a
        // platform view — so the bar went on resampling and blurring the map
        // on every frame of every drag. That is a full-width gaussian over the
        // most expensive backdrop in the app, sixty times a second, and it is
        // what the phone was getting warm doing.
        UiActivity.instance.setScrolling(true);
        // Deliberately no setState for the position itself: it arrives on
        // every frame of a drag, and the only things that care are the address
        // lookup (which runs when the camera stops) and the next camera move.
        _cameraCentre = LatLng(
          position.target.latitude,
          position.target.longitude,
        );
        _markerZoom = position.zoom;
        // Do not rebuild Flutter while the native map is under a pinch/drag.
        // Google Maps is already doing high-frequency work on the platform
        // thread; feeding every camera frame back into Riverpod/markers was the
        // path to ANR on quick zooms. Remember the visual state and apply it
        // once when the camera settles.
        _cameraClusterZoom = position.zoom.roundToDouble();
        _cameraRotated = position.bearing.abs() > 2;
        _cameraTilted = position.tilt > 5;
      },
      onCameraIdle: () {
        UiActivity.instance.setScrolling(false);
        _scheduleAddressLookup(_cameraCentre);
        if (_cameraClusterZoom != _clusterZoom ||
            _cameraRotated != _rotated ||
            _cameraTilted != _tilted) {
          setState(() {
            _clusterZoom = _cameraClusterZoom;
            _rotated = _cameraRotated;
            _tilted = _cameraTilted;
          });
        }
      },
    );
  }

  Widget _buildFallbackMap(
    List<_Node> nodes,
    LatLng? me,
    String nickname,
    Uint8List? ownPhoto,
  ) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedId = null;
          _mineSelected = false;
        });
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _TestMapBackdrop(),
          for (final node in nodes)
            Positioned(
              left: 72 +
                  (node.point.longitude - _fallbackCenter.longitude) * 4600,
              top:
                  318 - (node.point.latitude - _fallbackCenter.latitude) * 4600,
              child: SizedBox(
                width: _markerBox,
                height: _markerBox,
                child: _MapAvatar(
                  seed: node.id,
                  name: node.name,
                  photo: node.photo,
                  selected: node.id == _selectedId,
                  scale: _markerScale,
                  onTap: () {
                    setState(() {
                      _selectedId = node.id;
                      _mineSelected = false;
                    });
                  },
                ),
              ),
            ),
          if (me != null)
            Positioned(
              left: 154,
              top: 386,
              child: SizedBox(
                width: _markerBox,
                height: _markerBox,
                child: _MapAvatar(
                  key: const ValueKey('map-own-marker'),
                  seed: 'me',
                  name: nickname,
                  photo: ownPhoto,
                  selected: _mineSelected,
                  mine: true,
                  scale: _markerScale,
                  onTap: () {
                    setState(() {
                      _mineSelected = true;
                      _selectedId = null;
                    });
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The marker set, rebuilt only when something it depends on has moved.
  ///
  /// This screen rebuilds for a great many reasons that have nothing to do
  /// with the pins — an address coming back, a presence beacon, a friend list
  /// change, and every camera event — and rebuilding the set means the plugin
  /// diffs it and pushes the difference over the platform channel. During a
  /// pinch that was dozens of full marker updates a second, which is most of
  /// what made the map feel like treacle.
  Set<gm.Marker> _googleMarkers(
    List<_Node> nodes,
    LatLng? me,
    String nickname,
    Uint8List? ownPhoto,
  ) {
    final signature = [
      _clusterZoom.toStringAsFixed(0),
      _selectedId ?? '',
      _mineSelected ? 'me' : '',
      _markerIconGeneration.toString(),
      if (me != null)
        'me:${me.latitude.toStringAsFixed(5)},'
            '${me.longitude.toStringAsFixed(5)}',
      for (final node in nodes)
        '${node.id}:${node.point.latitude.toStringAsFixed(5)},'
            '${node.point.longitude.toStringAsFixed(5)}',
    ].join('|');
    final cached = _cachedMarkers;
    if (cached != null && signature == _cachedMarkersKey) return cached;

    final markers = _buildGoogleMarkers(nodes, me, nickname, ownPhoto);
    _cachedMarkers = markers;
    _cachedMarkersKey = signature;
    return markers;
  }

  Set<gm.Marker> _buildGoogleMarkers(
    List<_Node> nodes,
    LatLng? me,
    String nickname,
    Uint8List? ownPhoto,
  ) {
    final markers = <gm.Marker>{};
    final clusters = clusterByDistance<_Node>(
      nodes,
      pointOf: (node) => node.point,
      thresholdMetres:
          metresPerPixel(_cameraCentre.latitude, _clusterZoom) * 58,
    );

    for (final group in clusters) {
      if (group.length == 1) {
        final node = group.first;
        markers.add(
          gm.Marker(
            markerId: gm.MarkerId('peer:${node.id}'),
            position: _gm(node.point),
            // A circle marks its point with its middle. Google's default anchor
            // is the bottom centre, which is right for a tailed pin and would
            // leave this one floating above the place it means.
            anchor: const Offset(0.5, 0.5),
            zIndexInt: node.id == _selectedId ? 40 : 20,
            icon: _markerIcon(
              seed: node.id,
              name: node.name,
              photo: node.photo,
              selected: node.id == _selectedId,
            ),
            onTap: () {
              setState(() {
                _selectedId = node.id;
                _mineSelected = false;
              });
              _focusOn(node.point, zoom: _markerTapZoom);
            },
          ),
        );
        continue;
      }
      final point = _clusterCenter(group);
      markers.add(
        gm.Marker(
          // Named after the pin it formed around rather than after everybody
          // in it. A membership-derived id changes the moment anyone joins or
          // leaves the huddle, and a changed id is a marker destroyed and
          // recreated on the platform side instead of moved.
          markerId: gm.MarkerId('cluster:${group.first.id}'),
          position: _gm(point),
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 30,
          icon: _markerIcon(
            seed: 'cluster:',
            name: '',
            clusterCount: group.length,
          ),
          onTap: () => _openCluster(group),
        ),
      );
    }

    if (me != null) {
      markers.add(
        gm.Marker(
          markerId: const gm.MarkerId('me'),
          position: _gm(me),
          anchor: const Offset(0.5, 0.5),
          zIndexInt: _mineSelected ? 50 : 10,
          icon: _markerIcon(
            seed: 'me',
            name: nickname,
            photo: ownPhoto,
            mine: true,
            selected: _mineSelected,
          ),
          onTap: () {
            setState(() {
              _mineSelected = true;
              _selectedId = null;
            });
            _focusOn(me, zoom: _markerTapZoom);
          },
        ),
      );
    }
    return markers;
  }

  gm.BitmapDescriptor _markerIcon({
    required String seed,
    required String name,
    Uint8List? photo,
    bool mine = false,
    bool selected = false,
    int? clusterCount,
  }) {
    final photoStamp = photo == null
        ? 0
        : Object.hash(photo.length, photo.firstOrNull, photo.lastOrNull);
    // The screen's own scale is part of the key: the bitmap is rendered for
    // this device's pixels, and a cached one from another ratio would be the
    // wrong size. Constant in practice — it only ever changes if the app moves
    // to another display.
    final ratio = _markerPixelRatio(context);
    final key =
        '$seed:$photoStamp:$mine:$selected:${clusterCount ?? 0}:$ratio';
    final cached = _markerIcons[key];
    if (cached != null) return cached;

    if (_markerIconsInFlight.add(key)) {
      unawaited(
        _createMarkerIcon(
          name: name,
          photo: photo,
          mine: mine,
          selected: selected,
          clusterCount: clusterCount,
          ratio: ratio,
        ).then((icon) {
          if (!mounted) return;
          setState(() {
            _markerIcons[key] = icon;
            _markerIconGeneration++;
          });
        }).whenComplete(() => _markerIconsInFlight.remove(key)),
      );
    }

    return gm.BitmapDescriptor.defaultMarkerWithHue(
      mine || selected
          ? gm.BitmapDescriptor.hueAzure
          : gm.BitmapDescriptor.hueGreen,
    );
  }

  /// How many pixels of bitmap to draw per logical point of marker.
  ///
  /// The marker used to be a fixed 168-pixel bitmap shown at 84 points — two
  /// pixels per point, on phones that have three. So every face on the map was
  /// upscaled by half again and came out soft, which is what "make the avatars
  /// full quality" was about.
  ///
  /// Clamped at four: past that the gain is invisible and a map full of people
  /// is a lot of bitmaps to hold. Floored at two so a hypothetical 1x display
  /// does not get a marker rendered smaller than the one it replaced.
  static double _markerPixelRatio(BuildContext context) =>
      MediaQuery.devicePixelRatioOf(context).clamp(2.0, 4.0);

  Future<gm.BitmapDescriptor> _createMarkerIcon({
    required String name,
    Uint8List? photo,
    bool mine = false,
    bool selected = false,
    int? clusterCount,
    double ratio = 2,
  }) async {
    // A circle, which is what a face wants to be.
    //
    // It was briefly a teardrop, on the reasoning that a tail points at the
    // ground and makes the position exact. It does — and it reads worse: the
    // tail is a second shape competing with the face for the eye, at the size
    // a pin is actually drawn. Exactness is bought with the anchor instead
    // (see the marker's `anchor`), which costs nothing to look at.
    //
    // What does not come back is the clutter the circle used to carry: a
    // neon glow, a gradient band and a green dot in the corner that meant
    // nothing. Ring, face, shadow.
    // The space the drawing below is written in, and it stays 168 whatever the
    // screen is: every radius, offset and font size here is in these units, and
    // the canvas is scaled once rather than each of them being multiplied.
    const size = 168.0;
    // The circle fills about seven tenths of the bitmap, the rest being the
    // room the shadow and the selected glow need. So the drawn box has to be
    // bigger than the pin to *be* the size of the old pin — at 56 it came out
    // around forty points across, visibly smaller than the widget markers it
    // replaced.
    const logicalSize = 84.0;
    // What actually gets rasterised: the marker's size on screen times the
    // screen's own scale. 168 pixels for 84 points was two per point on phones
    // that have three, so every face was upscaled by half again.
    final pixels = (logicalSize * ratio).round();
    final scale = pixels / size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    const centre = Offset(size / 2, size / 2);
    final head = selected ? 62.0 : 58.0;

    canvas.drawCircle(
      centre.translate(0, 6),
      head,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.34)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    if (selected) {
      canvas.drawCircle(
        centre,
        head + 6,
        Paint()
          ..color = AppColors.brandPrimary.withValues(alpha: 0.34)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }

    canvas.drawCircle(
      centre,
      head,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: mine
              ? [AppColors.brandPrimary, AppColors.brandSecondary]
              : [AppColors.brandPrimary, const Color(0xFF8FF3C4)],
        ).createShader(Rect.fromCircle(center: centre, radius: head)),
    );

    // The face sits inside the ring rather than on top of it, so the ring
    // reads as the pin's edge and not as a second circle.
    final avatarRadius = head - 7;
    final avatarRect = Rect.fromCircle(center: centre, radius: avatarRadius);
    canvas.drawCircle(centre, avatarRadius, Paint()..color = AppColors.bgDeep);

    if (clusterCount != null) {
      canvas.drawCircle(
        centre,
        avatarRadius,
        Paint()..color = AppColors.brandPrimary.withValues(alpha: 0.22),
      );
      _drawMarkerText(
        canvas,
        '$clusterCount',
        centre,
        fontSize: clusterCount > 99 ? 34 : 44,
      );
    } else if (photo != null && photo.isNotEmpty) {
      try {
        // Decoded at the size it will actually occupy in pixels, not at a
        // fixed 128. On a 3x screen the face is drawn into roughly 150 pixels,
        // and handing it a 128-pixel decode is the second place the sharpness
        // was being thrown away.
        final facePixels = (avatarRadius * 2 * scale).ceil();
        final codec = await ui.instantiateImageCodec(
          photo,
          targetWidth: facePixels,
          targetHeight: facePixels,
        );
        final frame = await codec.getNextFrame();
        canvas.save();
        canvas.clipPath(ui.Path()..addOval(avatarRect));
        paintImage(
          canvas: canvas,
          rect: avatarRect,
          image: frame.image,
          fit: BoxFit.cover,
        );
        canvas.restore();
        frame.image.dispose();
      } catch (_) {
        _drawMarkerText(canvas, _initials(name), centre, fontSize: 40);
      }
    } else {
      _drawMarkerText(canvas, _initials(name), centre, fontSize: 40);
    }

    final image = await recorder.endRecording().toImage(pixels, pixels);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return gm.BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      // The bitmap is this many pixels per point, so the plugin draws it at
      // logicalSize and one bitmap pixel lands on one screen pixel.
      imagePixelRatio: ratio,
      width: logicalSize,
      height: logicalSize,
    );
  }

  void _drawMarkerText(
    Canvas canvas,
    String text,
    Offset center, {
    double fontSize = 30,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  String _initials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts =
        trimmed.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0].characters.first}${parts[1].characters.first}'
          .toUpperCase();
    }
    return trimmed.characters.first.toUpperCase();
  }

  LatLng _clusterCenter(List<_Node> group) {
    var lat = 0.0;
    var lon = 0.0;
    for (final node in group) {
      lat += node.point.latitude;
      lon += node.point.longitude;
    }
    return LatLng(lat / group.length, lon / group.length);
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

  void _resetBearing() {
    final controller = _googleMap;
    if (controller != null) {
      unawaited(
        controller.animateCamera(
          gm.CameraUpdate.newCameraPosition(
            gm.CameraPosition(target: _gm(_cameraCentre), zoom: _markerZoom),
          ),
        ),
      );
    }
    setState(() => _rotated = false);
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
    if (!_usesNativeMap) return;
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

  List<gm.Polyline> _googleLines(List<_Node> nodes, LatLng? me) {
    String cell(LatLng p) => '${p.latitude.toStringAsFixed(4)},'
        '${p.longitude.toStringAsFixed(4)}';
    final key = [
      if (me != null) 'me:${cell(me)}',
      for (final n in nodes) '${n.id}:${cell(n.point)}',
    ].join('|');
    final cached = _cachedLines;
    if (cached != null && key == _cachedLinesKey) return cached;
    final built = _buildGoogleLines(nodes, me);
    _cachedLines = built;
    _cachedLinesKey = key;
    return built;
  }

  List<gm.Polyline> _buildGoogleLines(List<_Node> nodes, LatLng? me) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final points = [if (me != null) me, ...nodes.map((n) => n.point)];
    if (points.length < 2) return const [];
    final used = <String>{};
    final result = <gm.Polyline>[];
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
        final path = [_gm(points[a]), _gm(points[b])];
        result
          ..add(
            gm.Polyline(
              polylineId: gm.PolylineId('web:$a:$b:halo'),
              points: path,
              width: math.max(1, (4 * pixelRatio).round()),
              color: AppColors.brandPrimary.withValues(alpha: 0.08),
              startCap: gm.Cap.roundCap,
              endCap: gm.Cap.roundCap,
              geodesic: true,
            ),
          )
          ..add(
            gm.Polyline(
              polylineId: gm.PolylineId('web:$a:$b'),
              points: path,
              width: math.max(1, (1.1 * pixelRatio).round()),
              color: AppColors.brandSecondary.withValues(alpha: 0.48),
              startCap: gm.Cap.roundCap,
              endCap: gm.Cap.roundCap,
              geodesic: true,
              zIndex: 1,
            ),
          );
      }
    }
    return result;
  }
}

gm.LatLng _gm(LatLng point) => gm.LatLng(point.latitude, point.longitude);

gm.MapType _googleMapType(MapLayer layer) => switch (layer) {
      MapLayer.standard => gm.MapType.normal,
      MapLayer.dark => gm.MapType.normal,
      MapLayer.satellite => gm.MapType.hybrid,
      MapLayer.terrain => gm.MapType.terrain,
    };

const _googleDarkStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#17222b"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"on"},{"saturation":-45},{"lightness":-10}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#a8bac8"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#0d151d"},{"weight":3}]},
  {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#344858"},{"visibility":"on"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#c6d2dc"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#22313b"},{"visibility":"on"}]},
  {"featureType":"poi","elementType":"labels.icon","stylers":[{"visibility":"on"},{"saturation":-55},{"lightness":-8}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#93a8b6"}]},
  {"featureType":"poi","elementType":"labels.text.stroke","stylers":[{"color":"#101920"},{"weight":3}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#30465a"},{"lightness":6}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#111b24"},{"weight":1}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#9cafbc"}]},
  {"featureType":"road","elementType":"labels.text.stroke","stylers":[{"color":"#0d151d"},{"weight":3}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3e5d77"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#162737"}]},
  {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#223543"},{"visibility":"on"}]},
  {"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#8598a6"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0b1822"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#6f8a9a"}]},
  {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#17242c"}]},
  {"featureType":"landscape.natural","elementType":"geometry","stylers":[{"color":"#18342b"}]}
]
''';

class _TestMapBackdrop extends StatelessWidget {
  const _TestMapBackdrop();

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          painter: _TestMapPainter(),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0A1713), Color(0xFF10261E)],
              ),
            ),
          ),
        ),
      );
}

class _TestMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final road = Paint()
      ..color = const Color(0xFF274538).withValues(alpha: 0.42)
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final minor = Paint()
      ..color = const Color(0xFF1A332B).withValues(alpha: 0.46)
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final park = Paint()
      ..color = const Color(0xFF0F3A2A).withValues(alpha: 0.35);

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.28, size.height * 0.32),
        width: size.width * 0.52,
        height: size.height * 0.26,
      ),
      park,
    );

    for (var i = -2; i < 9; i++) {
      final y = size.height * (0.12 + i * 0.105);
      canvas.drawLine(Offset(-30, y), Offset(size.width + 40, y + 90), minor);
    }
    for (var i = -1; i < 7; i++) {
      final x = size.width * (0.08 + i * 0.17);
      canvas.drawLine(Offset(x, -20), Offset(x - 60, size.height + 30), minor);
    }
    canvas.drawLine(
      Offset(size.width * 0.12, size.height * 0.84),
      Offset(size.width * 0.82, size.height * 0.12),
      road,
    );
    canvas.drawLine(
      Offset(size.width * 0.05, size.height * 0.48),
      Offset(size.width * 0.95, size.height * 0.54),
      road,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
                Icons.location_off_rounded,
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
        // See the address pane above: nothing blurs the map.
        blur: false,
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
        blur: false,
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
