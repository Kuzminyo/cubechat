import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/shared_location.dart';
import '../../../core/util/app_lifecycle.dart';
import '../../../core/util/location_service.dart';
import '../../profile/data/privacy_settings_controller.dart';
import 'map_friends_controller.dart';

/// Periodically refreshes our live position for confirmed map friends.
///
/// Kept light on purpose: foreground only, one-shot fixes instead of a running
/// stream, and a short expiry so stale pins vanish if updates stop.
class MapPresenceController extends Notifier<int> {
  static const _tick = Duration(seconds: 45);
  static const _ttl = Duration(minutes: 2);

  Timer? _timer;
  bool _sending = false;
  DateTime? _lastSentAt;
  String? _lastCell;

  @override
  int build() {
    _arm();
    ref.listen<Set<String>>(mapFriendsControllerProvider, (_, __) => _arm());
    ref.listen<PrivacySettings>(privacySettingsProvider, (before, after) {
      // Switching map sharing off has to *retract* the pin, not merely stop
      // refreshing it. Stopping leaves the last beacon standing on every
      // friend's map until its own two-minute TTL lapses — so the switch that
      // means "nobody sees where I am" would still show where you were, for two
      // minutes, which is the whole of what someone reaches for it to prevent.
      if ((before?.shareMapLocation ?? false) && !after.shareMapLocation) {
        unawaited(withdraw());
      }
      _arm();
    });
    ref.onDispose(() => _timer?.cancel());
    return 0;
  }

  /// Tell every map friend to drop our pin, now.
  ///
  /// A flagged, already-expired beacon rather than a new payload type: the
  /// receiver reads the flag as "remove this person", so retraction costs no
  /// protocol surface, and an older build sees a position that expired before
  /// it arrived and lets the pin lapse as it always did.
  Future<void> withdraw() async {
    _lastCell = null;
    _lastSentAt = null;
    final peers = ref.read(mapFriendsControllerProvider).toList(growable: false);
    if (peers.isEmpty) return;
    final gone = SharedLocation(
      latitude: 0,
      longitude: 0,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      presence: true,
      retract: true,
    ).encode();
    final messaging = ref.read(messagingServiceProvider);
    for (final peerId in peers) {
      try {
        await messaging.sendText(peerId, gone, transient: true);
      } catch (e) {
        debugPrint('MapPresenceController withdraw failed for $peerId: $e');
      }
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => unawaited(_sendUpdate()));
    unawaited(_sendUpdate(force: true));
  }

  Future<void> pokeNow() => _sendUpdate(force: true);

  Future<void> _sendUpdate({bool force = false}) async {
    if (_sending) return;
    if (!AppLifecycle.instance.isForeground) return;
    if (!ref.read(privacySettingsProvider).shareMapLocation) return;
    final peers = ref.read(mapFriendsControllerProvider).toList(growable: false);
    if (peers.isEmpty) return;

    _sending = true;
    try {
      final (fix, _) = await const LocationService().current();
      if (fix == null) return;

      final now = DateTime.now();
      final cell =
          '${fix.latitude.toStringAsFixed(4)}:${fix.longitude.toStringAsFixed(4)}';
      if (!force &&
          _lastCell == cell &&
          _lastSentAt != null &&
          now.difference(_lastSentAt!) < const Duration(seconds: 35)) {
        return;
      }

      final share = SharedLocation(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyMetres: fix.accuracyMetres,
        expiresAt: now.add(_ttl),
        presence: true,
      ).encode();

      final messaging = ref.read(messagingServiceProvider);
      for (final peerId in peers) {
        try {
          await messaging.sendText(peerId, share, transient: true);
        } catch (e) {
          debugPrint('MapPresenceController send failed for $peerId: $e');
        }
      }
      _lastCell = cell;
      _lastSentAt = now;
    } finally {
      _sending = false;
    }
  }
}

final mapPresenceControllerProvider =
    NotifierProvider<MapPresenceController, int>(MapPresenceController.new);
