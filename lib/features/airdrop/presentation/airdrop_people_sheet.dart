import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/peer_discovery_controller.dart';
import '../../peers/data/peripheral_controller.dart';
import '../data/airdrop_controller.dart' show airdropPeerNameProvider;
import '../data/bump_controller.dart' show bumpDialProvider;

@immutable
class AirDropPeer {
  const AirDropPeer(this.hex, this.name);

  final String hex;
  final String name;
}

/// Everyone with a Bluetooth session to this phone right now — the only
/// people AirDrop can reach. Recomputed when sessions or peripheral links
/// change.
final airdropDirectPeersProvider = Provider<List<AirDropPeer>>((ref) {
  ref.watch(chatSessionManagerProvider);
  ref.watch(peripheralControllerProvider);
  final names = ref.watch(airdropPeerNameProvider);
  return [
    for (final hex in ref.watch(messagingServiceProvider).directPeerHexes())
      AirDropPeer(hex, names(hex)),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

/// One row of the people sheet: somebody linked, somebody the scan sees
/// running CubeChat, or both at once.
@immutable
class AirDropCandidate {
  const AirDropCandidate({
    required this.key,
    required this.linked,
    this.hex,
    this.device,
    this.name,
    this.rssi,
  });

  /// The identity when known, otherwise `scan:<device>`.
  final String key;

  /// Whether a direct session is up — a tap sends straight away.
  final bool linked;

  /// Null for a phone nobody has put a name to yet: a stranger is only known
  /// after the handshake.
  final String? hex;

  /// The platform address the scan heard it on — what a dial rings. Null for
  /// a linked peer the scan does not currently see.
  final String? device;

  /// Null draws the localized "Nearby".
  final String? name;
  final int? rssi;
}

/// Who the people sheet offers: everyone linked, plus everyone the scan sees
/// running CubeChat, one row per person. Linked first, then the loudest.
///
/// Build 1110 and before listed only the linked, and only a tap in Nearby (or
/// a bump) links anybody — so a person standing right there was missing from
/// AirDrop until you went to another tab and tapped them.
final airdropNearbyPeopleProvider = Provider<List<AirDropCandidate>>((ref) {
  final linked = ref.watch(airdropDirectPeersProvider);
  final names = ref.watch(airdropPeerNameProvider);
  final sessions = ref.watch(chatSessionManagerProvider);
  final scanned = ref.watch(peerDiscoveryControllerProvider).peers;
  final linkedHexes = {for (final p in linked) p.hex};

  // The scan names a phone by roster match; one it cannot name may still be
  // somebody a session already proved — a stranger right after the handshake.
  final heard = <String, ({String device, int? rssi})>{};
  final anonymous = <({String device, int? rssi})>[];
  for (final p in scanned) {
    final rssi = p.hasSignalReading ? p.rssi : null;
    final session = sessions[p.id];
    final hex = p.resolvedPubkeyHex ??
        (session != null && session.isEstablished
            ? session.remotePubkeyHex
            : null);
    if (hex == null) {
      anonymous.add((device: p.id, rssi: rssi));
      continue;
    }
    final before = heard[hex];
    if (before == null || (rssi ?? -999) > (before.rssi ?? -999)) {
      heard[hex] = (device: p.id, rssi: rssi);
    }
  }

  final out = <AirDropCandidate>[
    for (final p in linked)
      AirDropCandidate(
        key: p.hex,
        linked: true,
        hex: p.hex,
        device: heard[p.hex]?.device,
        name: p.name,
        rssi: heard[p.hex]?.rssi,
      ),
    for (final e in heard.entries)
      if (!linkedHexes.contains(e.key))
        AirDropCandidate(
          key: e.key,
          linked: false,
          hex: e.key,
          device: e.value.device,
          name: names(e.key),
          rssi: e.value.rssi,
        ),
    for (final a in anonymous)
      AirDropCandidate(
        key: 'scan:${a.device}',
        linked: false,
        device: a.device,
        rssi: a.rssi,
      ),
  ];
  int byLoudness(AirDropCandidate a, AirDropCandidate b) =>
      (b.rssi ?? -999).compareTo(a.rssi ?? -999);
  return out
    ..sort((a, b) {
      if (a.linked != b.linked) return a.linked ? -1 : 1;
      final loud = byLoudness(a, b);
      if (loud != 0) return loud;
      return (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase());
    });
});

Future<AirDropPeer?> showAirDropPeopleSheet(BuildContext context) =>
    showGlassSheet<AirDropPeer>(
      context: context,
      useRootNavigator: true,
      builder: (sheet) => AirDropPeopleList(
        onPick: (peer) => Navigator.of(sheet).pop(peer),
      ),
    );

/// A tap on somebody with no session rings them and waits for the session.
class _Dial {
  _Dial(this.hex, this.timeout);

  final String? hex;
  final Timer timeout;
}

class AirDropPeopleList extends ConsumerStatefulWidget {
  const AirDropPeopleList({super.key, required this.onPick});

  /// Called once, with the identity the session proved — never a scan id.
  final ValueChanged<AirDropPeer> onPick;

  /// How long a tap waits for a session before saying it could not connect.
  static const Duration connectTimeout = Duration(seconds: 15);

  @override
  ConsumerState<AirDropPeopleList> createState() => _AirDropPeopleListState();
}

class _AirDropPeopleListState extends ConsumerState<AirDropPeopleList> {
  /// Device being dialled → the dial. Keyed by device because a stranger's
  /// row changes key (from `scan:` to their identity) when the handshake ends.
  final Map<String, _Dial> _dials = {};
  bool _picked = false;

  @override
  void dispose() {
    // Closing the sheet cancels the wait: a session that comes up later
    // sends nothing.
    _cancelAll();
    super.dispose();
  }

  void _cancelAll() {
    for (final d in _dials.values) {
      d.timeout.cancel();
    }
    _dials.clear();
  }

  void _pick(String hex) {
    if (_picked || !mounted) return;
    _picked = true;
    _cancelAll();
    widget.onPick(AirDropPeer(hex, ref.read(airdropPeerNameProvider)(hex)));
  }

  void _tap(AirDropCandidate c) {
    if (_picked) return;
    final hex = c.hex;
    if (c.linked && hex != null) {
      _pick(hex);
      return;
    }
    final device = c.device;
    if (device == null || _dials.containsKey(device)) return;
    final dial = _Dial(
      hex,
      Timer(AirDropPeopleList.connectTimeout, () => _fail(device)),
    );
    setState(() => _dials[device] = dial);
    // The same dialler the bump uses, which rings the way a tap in Nearby
    // does: no third copy of the retry and address-refresh rules.
    unawaited(() async {
      String? who;
      try {
        who = await ref.read(bumpDialProvider)(device, hex);
      } catch (_) {
        who = null;
      }
      if (!mounted || !identical(_dials[device], dial)) return;
      if (who != null) {
        _pick(who);
      } else {
        // Nothing yet: the handshake may still land before the timeout, and
        // [_watchLinks] picks it up then.
        _watchLinks(ref.read(airdropNearbyPeopleProvider));
      }
    }());
  }

  void _fail(String device) {
    if (!mounted || _dials.remove(device) == null) return;
    setState(() {});
    showGlassToast(
      context,
      AppLocalizations.of(context).airdropConnectFailed,
      tone: ToastTone.danger,
    );
  }

  /// A session to somebody being dialled, however it came up — the dial's
  /// own answer, or the other phone ringing us at the same moment.
  void _watchLinks(List<AirDropCandidate> people) {
    if (_picked || _dials.isEmpty) return;
    for (final c in people) {
      final hex = c.hex;
      if (!c.linked || hex == null) continue;
      final match = (c.device != null && _dials.containsKey(c.device)) ||
          _dials.values.any((d) => d.hex == hex);
      if (match) {
        _pick(hex);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    ref.listen<List<AirDropCandidate>>(
      airdropNearbyPeopleProvider,
      (_, next) => _watchLinks(next),
    );
    final people = ref.watch(airdropNearbyPeopleProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.airdropPickPerson,
            style:
                AppTypography.heading(size: 18, color: AppColors.textOnGlass),
          ),
          const SizedBox(height: 12),
          if (people.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                t.airdropNobody,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in people)
                    Padding(
                      key: ValueKey(c.key),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _PersonRow(
                        candidate: c,
                        name: c.name ?? t.airdropNearbyUnknown,
                        connecting:
                            c.device != null && _dials.containsKey(c.device),
                        connectingLabel: t.airdropConnecting,
                        onTap: () => _tap(c),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.candidate,
    required this.name,
    required this.connecting,
    required this.connectingLabel,
    required this.onTap,
  });

  final AirDropCandidate candidate;
  final String name;
  final bool connecting;
  final String connectingLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FloatingGlass(
      blur: false,
      borderRadius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: onTap,
      child: Row(
        children: [
          IdentityAvatar(
            seed: candidate.hex ?? candidate.key,
            label: name,
            size: 40,
            online: candidate.linked,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (connecting)
                  Text(
                    connectingLabel,
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
          if (connecting)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.brandPrimary,
              ),
            )
          else
            Icon(
              candidate.linked
                  ? Icons.bluetooth_connected_rounded
                  : Icons.bluetooth_rounded,
              color: candidate.linked
                  ? AppColors.brandPrimary
                  : AppColors.textOnGlassDim,
              size: 18,
            ),
        ],
      ),
    );
  }
}
