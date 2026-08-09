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
import '../../../core/util/ui_activity.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/data/peer_avatars_controller.dart';
import '../../profile/data/privacy_settings_controller.dart';
import '../data/map_address_service.dart';
import '../data/shared_map_locations_provider.dart';
import 'map_invite_sheet.dart';

typedef MapLocationReader = Future<(LocationFix?, LocationFailure?)> Function();
typedef MapAddressReader = Future<String?> Function(
  double latitude,
  double longitude,
  Locale locale,
);

final mapTileProviderProvider = Provider<TileProvider?>((ref) => null);
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

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
    lowerBound: 0.48,
    upperBound: 0.82,
  );

  @override
  void initState() {
    super.initState();
    UiActivity.instance.isQuiet.addListener(_syncAnimation);
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
    _syncAnimation();
  }

  void _syncAnimation() {
    if (!mounted) return;
    if (_watching && !UiActivity.instance.isQuiet.value) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
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
    if (fix != null && (recenter || !_centered)) {
      final point = LatLng(fix.latitude, fix.longitude);
      _centered = true;
      _map.move(point, 14);
      _scheduleAddressLookup(point);
    }
  }

  @override
  void dispose() {
    AppLifecycle.instance.isWatchingMap = false;
    _refresh?.cancel();
    _addressDebounce?.cancel();
    UiActivity.instance.isQuiet.removeListener(_syncAnimation);
    _pulse.dispose();
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
    final nickname = ref.watch(nicknameControllerProvider);
    final ownPhoto = ref.watch(avatarProvider);
    final nodes = <_Node>[
      for (final entry in shared.entries)
        if (!entry.value.location.expired && peers[entry.key] != null)
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
                        onPressed: () => showMapInviteSheet(context),
                        tooltip: t.mapInviteTitle,
                        icon: Icon(
                          Icons.person_add_alt_1_rounded,
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
            child: _MapActionButton(
              icon: Icons.my_location_rounded,
              tooltip: t.mapCenterMe,
              onTap: _locating ? null : _centerOnMe,
              loading: _locating,
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

  Future<void> _centerOnMe() async {
    await _locate(recenter: true);
  }

  Widget _buildMap(
    List<_Node> nodes,
    LatLng? mePoint,
    String nickname,
    Uint8List? ownPhoto,
    TileProvider? tileProvider,
  ) {
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _fallbackCenter,
        initialZoom: _initialZoom,
        minZoom: 3,
        maxZoom: 18,
        backgroundColor: const Color(0xFF101A22),
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () => _scheduleAddressLookup(_fallbackCenter),
        onTap: (_, __) => setState(() {
          _selectedId = null;
          _mineSelected = false;
        }),
        onMapEvent: (event) {
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
        RepaintBoundary(
          child: TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.cubechat.cubechat',
            tileProvider: tileProvider,
            maxNativeZoom: 19,
            keepBuffer: 1,
            panBuffer: 0,
            tileDisplay: const TileDisplay.instantaneous(opacity: 0.18),
            tileUpdateTransformer: TileUpdateTransformers.throttle(
              const Duration(milliseconds: 180),
            ),
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
          ),
        ),
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.58),
          ),
        ),
        IgnorePointer(
          child: ColoredBox(
            color: AppColors.brandPrimary.withValues(alpha: 0.025),
          ),
        ),
        if (nodes.length > 1 && nodes.length <= 16)
          FadeTransition(
            opacity: _pulse,
            child: RepaintBoundary(
              child: PolylineLayer(
                polylines: _lines(nodes, mePoint),
              ),
            ),
          ),
        MarkerLayer(
          markers: [
            if (mePoint != null)
              Marker(
                point: mePoint,
                width: 72,
                height: 72,
                child: _MapAvatar(
                  key: const ValueKey('map-own-marker'),
                  seed: 'me',
                  name: nickname,
                  photo: ownPhoto,
                  mine: true,
                  selected: _mineSelected,
                  onTap: () => setState(() {
                    _mineSelected = true;
                    _selectedId = null;
                  }),
                ),
              ),
            for (final node in nodes)
              Marker(
                point: node.point,
                width: 72,
                height: 72,
                child: _MapAvatar(
                  seed: node.id,
                  name: node.name,
                  photo: node.photo,
                  selected: node.id == _selectedId,
                  onTap: () => setState(() {
                    _selectedId = node.id;
                    _mineSelected = false;
                  }),
                ),
              ),
          ],
        ),
        RichAttributionWidget(
          attributions: [
            TextSourceAttribution(
              'OpenStreetMap contributors',
              onTap: () => launchUrl(
                Uri.parse('https://www.openstreetmap.org/copyright'),
              ),
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
    this.onTap,
  });

  final String seed;
  final String name;
  final Uint8List? photo;
  final bool selected;
  final bool mine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final size = selected ? 58.0 : 52.0;
    return GestureDetector(
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
