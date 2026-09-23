import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/announcement.dart';
import '../../../core/transport/contact_card.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/debug_log.dart';
import '../../peers/data/peer_discovery_controller.dart';
import '../domain/proximity_tracker.dart';
import '../presentation/airdrop_navigation.dart'
    show airdropPageOnScreenProvider;
import '../presentation/airdrop_people_sheet.dart'
    show airdropDirectPeersProvider;
import 'airdrop_clock.dart';
import 'airdrop_controller.dart';
import 'airdrop_port.dart';
import 'airdrop_source.dart';
import 'airdrop_staged.dart';
import 'bump_ledger.dart';

/// What a matched bump turned into — the card the page shows once.
sealed class BumpEvent {
  const BumpEvent(this.peerHex, this.peerName, this.at);

  final String peerHex;
  final String peerName;
  final DateTime at;
}

/// Our staged files went to them as an ordinary offer.
class BumpSentFiles extends BumpEvent {
  const BumpSentFiles(super.peerHex, super.peerName, super.at, this.count);

  final int count;
}

/// They have files and we had none: their offer is on its way, and the ledger
/// lets it in without a question.
class BumpReceivingFiles extends BumpEvent {
  const BumpReceivingFiles(super.peerHex, super.peerName, super.at);
}

/// Nobody had files: a swap of contact cards. Nothing is added until the
/// person presses "Додати" — [BumpController.addContact].
class BumpContact extends BumpEvent {
  const BumpContact(
    super.peerHex,
    super.peerName,
    super.at, {
    required this.card,
    required this.alreadyContact,
  });

  /// Their signed `PeerAnnouncement`, already checked to be the sender's.
  final Uint8List card;
  final bool alreadyContact;
}

@immutable
class BumpState {
  const BumpState({this.warmth = 0, this.event});

  /// 0..1: how close the nearest person is, for the glow. 0 draws nothing.
  final double warmth;
  final BumpEvent? event;
}

/// One signal reading the scan handed over. [seen] is when the advertisement
/// behind it arrived — the discovery list is re-emitted whenever *anyone* in
/// it moves, and without it an unchanged -35 would be counted again each time
/// somebody else's signal wobbled. [device] is the platform device id the
/// reading came from, whatever [hex] it is filed under.
typedef BumpReading = ({String hex, String device, int rssi, DateTime seen});

/// Own signed card, injectable for tests.
final bumpOwnCardProvider = Provider<Future<Uint8List> Function()>(
  (ref) => () => ref.read(messagingServiceProvider).buildSignedAnnouncement(),
);

/// Who has a direct session now, injectable for tests.
final bumpDirectPeersProvider = Provider<Set<String>>(
  (ref) => {for (final p in ref.watch(airdropDirectPeersProvider)) p.hex},
);

/// Adds a contact from their signed card; the pubkey hex. Injectable for
/// tests.
final bumpAddContactProvider = Provider<Future<String> Function(Uint8List)>(
  (ref) => (card) => ref
      .read(messagingServiceProvider)
      .addContactFromCard(ContactCard.encode(card)),
);

/// Whether [card] is a validly signed announcement of [senderHex] itself.
/// A bump carrying somebody else's card would put a stranger's name on the
/// contact card the person is about to add.
final bumpCardCheckProvider =
    Provider<Future<bool> Function(Uint8List card, String senderHex)>(
  (ref) => (card, senderHex) async {
    try {
      final ann = await PeerAnnouncement.verifyAndDecode(card);
      return nearbyHex(ann.pubkey) == senderHex;
    } catch (_) {
      return false;
    }
  },
);

/// The scan's readings. Auto-disposed: the controller listens only while the
/// AirDrop page is open, so the list is not rebuilt on every advertisement
/// the rest of the time.
///
/// A phone nobody can put a name to still goes in, under `anon:<device id>`:
/// it can never be bumped (it has no session), but a louder one must still
/// stop a quieter named phone from counting as the one touching.
final bumpReadingsProvider = Provider.autoDispose<List<BumpReading>>(
  (ref) => [
    for (final p in ref.watch(peerDiscoveryControllerProvider).peers)
      if (p.hasSignalReading)
        (
          hex: p.resolvedPubkeyHex ?? '$bumpAnonPrefix${p.id}',
          device: p.id,
          rssi: p.rssi,
          seen: p.lastSeen,
        ),
  ],
);

/// Key prefix of a reading from a phone with no known identity.
const String bumpAnonPrefix = 'anon:';

/// The bump gesture: two phones held together on the open AirDrop page agree
/// they touched, then send the staged files or swap contact cards.
///
/// Neither phone can impose it: each sends a `nearbyBump` when *it* reads the
/// other as touching, and acts only when the other's arrives within
/// [mutualWithin] of its own, in either order.
class BumpController extends Notifier<BumpState> {
  static const Duration mutualWithin = Duration(seconds: 2);
  static const Duration cooldown = Duration(seconds: 5);

  static const Duration _tickEvery = Duration(milliseconds: 200);
  static const Duration _logEvery = Duration(seconds: 1);

  /// How long a bump id is remembered against replay, and how many at most.
  /// A minute is thirty times the window a replay would have to land in, and
  /// the cap keeps a flood from a hostile peer to a few kilobytes.
  static const Duration _idsFor = Duration(minutes: 1);
  static const int _maxIds = 256;

  final ProximityTracker _tracker = ProximityTracker();
  final Map<String, DateTime> _sentAt = {};
  final Map<String, ({DateTime at, NearbyBump bump})> _heard = {};
  final Map<String, DateTime> _quietUntil = {};

  /// Bump id → when it arrived, oldest first.
  final LinkedHashMap<String, DateTime> _seenIds = LinkedHashMap();

  /// Newest advertisement already fed, per person — see [BumpReading].
  final Map<String, DateTime> _fed = {};

  /// Device id → the key its readings were last filed under — see
  /// [_onReadings].
  final Map<String, String> _keyOfDevice = {};

  /// Our bump to each person as it is being handed to the port. A bumped
  /// offer waits on it: the receiver opens its door for the offer when our
  /// bump arrives, so an offer that overtook it would be met by a closed one.
  final Map<String, Future<void>> _sending = {};

  StreamSubscription<NearbyInbound>? _inbound;
  ProviderSubscription<List<BumpReading>>? _readings;
  Timer? _tick;

  /// Bumped on every page open, so a card check that started before the page
  /// closed cannot land in the next visit.
  int _visit = 0;
  DateTime? _lastLog;

  /// Our signed card for this visit. Fetched when the page opens: building it
  /// signs an announcement, which the first bump of a visit should not wait
  /// on.
  Future<Uint8List>? _ownCard;
  final _random = Random.secure();

  DateTime get _now => ref.read(airdropClockProvider)();

  @override
  BumpState build() {
    _inbound = ref.read(airdropPortProvider).inbound.listen(_onInbound);
    // Not fireImmediately: stopping writes `state`, which cannot be read
    // before build() has returned.
    ref.listen<bool>(
      airdropPageOnScreenProvider,
      (_, on) => on ? _start() : _stop(),
    );
    ref.onDispose(() {
      unawaited(_inbound?.cancel());
      _tick?.cancel();
      _tick = null;
      _readings?.close();
      _readings = null;
    });
    if (ref.read(airdropPageOnScreenProvider)) _start();
    return const BumpState();
  }

  void _start() {
    if (_tick != null) return;
    _visit++;
    _tick = Timer.periodic(_tickEvery, (_) => _evaluate());
    _readings = ref.listen<List<BumpReading>>(
      bumpReadingsProvider,
      (_, next) => _onReadings(next),
    );
    _ownCard = _loadCard();
  }

  /// Staged files are deliberately left alone here: Android's system picker
  /// pauses the app, which turns the page "off" — clearing them on the way
  /// out wiped the very selection being made. They go when they are sent, or
  /// when the person clears them.
  void _stop() {
    _tick?.cancel();
    _tick = null;
    _readings?.close();
    _readings = null;
    _tracker.clear();
    _fed.clear();
    _keyOfDevice.clear();
    _sentAt.clear();
    _heard.clear();
    _sending.clear();
    // Built afresh on the next visit: the name or the picture may have
    // changed in between.
    _ownCard = null;
    if (state.warmth != 0) state = BumpState(event: state.event);
  }

  Future<Uint8List> _loadCard() {
    final card = ref.read(bumpOwnCardProvider)();
    // Observed here so a failure is not an unhandled error while nobody is
    // bumping yet; the next bump asks again.
    unawaited(
      card.then<void>(
        (_) {},
        onError: (Object e) {
          if (identical(_ownCard, card)) _ownCard = null;
          DebugLog.instance.log('BUMP', 'own card unavailable: $e');
        },
      ),
    );
    return card;
  }

  void _onReadings(List<BumpReading> readings) {
    for (final r in readings) {
      // A phone read as `anon:` a moment ago and named now is one phone, not
      // two. Its anonymous readings would otherwise be held for the tracker's
      // three seconds at the very same RSSI — a runner-up zero dB behind that
      // fails the margin, so the phone blocked its own bump right after it
      // resolved (and again after every rotating-id epoch change).
      final before = _keyOfDevice[r.device];
      if (before != null &&
          before != r.hex &&
          before.startsWith(bumpAnonPrefix)) {
        _tracker.forget(before);
        _fed.remove(before);
      }
      _keyOfDevice[r.device] = r.hex;
      final last = _fed[r.hex];
      if (last != null && !r.seen.isAfter(last)) continue;
      _fed[r.hex] = r.seen;
      sample(r.hex, r.rssi);
    }
  }

  /// Fed by the scan; public so the page's listener and the tests can drive it.
  ///
  /// Everyone the scan can name goes into the tracker, not only people with a
  /// session: the spec's margin is over "any other person nearby", and a
  /// louder phone we cannot reach must still stop a quieter one from counting
  /// as the one touching. Who may be *bumped* is checked in [_evaluate].
  void sample(String peerHex, int rssi) {
    if (_tick == null) return;
    _tracker.add(peerHex, rssi, _now);
  }

  void dismiss() {
    if (state.event != null) state = BumpState(warmth: state.warmth);
  }

  /// Adds the card of the current [BumpContact]; the pubkey hex, or null
  /// when there is no such card or it could not be added.
  Future<String?> addContact() async {
    final e = state.event;
    if (e is! BumpContact) return null;
    final add = ref.read(bumpAddContactProvider);
    try {
      final hex = await add(e.card);
      if (identical(state.event, e)) dismiss();
      return hex;
    } catch (err) {
      DebugLog.instance.log('BUMP', 'adding ${_short(e.peerHex)} failed: $err');
      return null;
    }
  }

  void _evaluate() {
    final now = _now;
    final r = _tracker.read(now);
    final w = r.warmth;
    // A twentieth is finer than the glow can show; the two ends always land,
    // or a glow could stay lit at 0.03 after the person walked away.
    if (w != state.warmth &&
        ((w - state.warmth).abs() >= 0.05 || w == 0 || w == 1)) {
      state = BumpState(warmth: w, event: state.event);
    }
    _logReading(r, now);
    final hex = r.closest;
    if (!r.isClose || hex == null || _quiet(hex, now)) return;
    if (!ref.read(bumpDirectPeersProvider).contains(hex)) return;
    final sent = _sentAt[hex];
    // Held together, ours goes again every [mutualWithin], so a slow other
    // side still finds one of ours recent enough.
    if (sent != null && now.difference(sent) < mutualWithin) return;
    _sentAt[hex] = now;
    _sending[hex] = _sendBump(hex);
    final heard = _heard[hex];
    if (heard != null && now.difference(heard.at) <= mutualWithin) {
      _fire(hex, heard.bump, now);
    }
  }

  /// Never throws: a bumped offer awaits it.
  Future<void> _sendBump(String hex) async {
    final port = ref.read(airdropPortProvider);
    final hasFiles = ref.read(airdropStagedProvider).isNotEmpty;
    final card = _ownCard ??= _loadCard();
    try {
      final ok = await port.send(
        hex,
        bump: NearbyBump(bumpId: _newId(), hasFiles: hasFiles, card: await card),
      );
      if (!ok) DebugLog.instance.log('BUMP', 'could not reach ${_short(hex)}');
    } catch (e) {
      DebugLog.instance.log('BUMP', 'sending to ${_short(hex)} failed: $e');
    }
  }

  /// Synchronous on purpose, up to the ledger note in [_fire]: the offer that
  /// follows their bump is judged by `AirDropController` the moment it lands,
  /// and anything awaited here first (the Ed25519 card check was) let it land
  /// before the door was opened — a stranger's bumped offer then read as an
  /// ordinary one and was declined for "contacts only".
  ///
  /// The sender is already known without the card: [NearbyInbound.direct]
  /// means it came over the Noise session with [NearbyInbound.peerHex]. The
  /// card is only shown — and checked — for a contact swap, in [_contact].
  void _onInbound(NearbyInbound m) {
    final bump = m.bump;
    if (bump == null || !m.direct || _tick == null) return;
    final hex = m.peerHex;
    final at = _now;
    if (!_remember(nearbyHex(bump.bumpId), at)) return;
    // Quiet means quiet: a bump from them in the pause is the same pair of
    // phones still lying together, not a new gesture waiting to happen.
    if (_quiet(hex, at)) return;
    _heard[hex] = (at: at, bump: bump);
    final sent = _sentAt[hex];
    if (sent != null && at.difference(sent) <= mutualWithin) {
      _fire(hex, bump, at);
    }
  }

  void _fire(String hex, NearbyBump theirs, DateTime now) {
    _quietUntil[hex] = now.add(cooldown);
    // The ledger is a door for *their* offer, auto-accepted: opened only when
    // their bump said files are coming. A bump without files is a contact
    // swap, and a stranger must not get a free offer out of it too.
    if (theirs.hasFiles) ref.read(bumpLedgerProvider).note(hex, now);
    _sentAt.remove(hex);
    _heard.remove(hex);
    final ours = _sending.remove(hex) ?? Future<void>.value();
    DebugLog.instance.log('BUMP', 'fired with ${_short(hex)}');
    final name = ref.read(airdropPeerNameProvider)(hex);
    final staged = ref.read(airdropStagedProvider);
    if (staged.isNotEmpty) {
      _show(BumpSentFiles(hex, name, now, staged.length));
      unawaited(_offer(hex, name, staged, after: ours));
    } else if (theirs.hasFiles) {
      _show(BumpReceivingFiles(hex, name, now));
    } else {
      unawaited(_contact(hex, name, theirs.card, now));
    }
  }

  void _show(BumpEvent event) =>
      state = BumpState(warmth: state.warmth, event: event);

  /// A contact swap shows their card only once it is proven to be theirs.
  ///
  /// The "not their card" line needs no limiter of its own: this runs only
  /// after a fire, and a fire starts the per-person [cooldown], so it is
  /// written at most once per person per five seconds.
  Future<void> _contact(
    String hex,
    String name,
    Uint8List card,
    DateTime at,
  ) async {
    final visit = _visit;
    final check = ref.read(bumpCardCheckProvider);
    bool ok;
    try {
      ok = await check(card, hex);
    } catch (_) {
      ok = false;
    }
    // The page may have closed (or the app ended) while the card was being
    // checked: nothing to show it on now.
    if (_tick == null || visit != _visit) return;
    if (!ok) {
      DebugLog.instance.log('BUMP', 'no card from ${_short(hex)}: not theirs');
      return;
    }
    _show(
      BumpContact(
        hex,
        name,
        at,
        card: card,
        alreadyContact: ref.read(airdropContactsProvider).contains(hex),
      ),
    );
  }

  /// Sends [files] once our bump has been handed to the port — see
  /// [_sending] — and lets go of the staging only once the offer is out.
  Future<void> _offer(
    String hex,
    String name,
    List<AirDropSource> files, {
    required Future<void> after,
  }) async {
    final airdrop = ref.read(airdropControllerProvider.notifier);
    final staged = ref.read(airdropStagedProvider.notifier);
    await after;
    try {
      final t = await airdrop.offer(peerHex: hex, peerName: name, files: files);
      if (t == null) {
        DebugLog.instance.log('BUMP', 'offer to ${_short(hex)} did not go');
        return;
      }
      // Only if the person has not picked something else meanwhile.
      if (identical(staged.state, files)) staged.state = const [];
    } catch (e) {
      DebugLog.instance.log('BUMP', 'offer to ${_short(hex)} failed: $e');
    }
  }

  bool _quiet(String hex, DateTime now) {
    final until = _quietUntil[hex];
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    _quietUntil.remove(hex);
    return false;
  }

  /// False when [id] was seen within [_idsFor] — a replayed frame.
  bool _remember(String id, DateTime now) {
    while (_seenIds.isNotEmpty &&
        now.difference(_seenIds.values.first) > _idsFor) {
      _seenIds.remove(_seenIds.keys.first);
    }
    if (_seenIds.containsKey(id)) return false;
    _seenIds[id] = now;
    if (_seenIds.length > _maxIds) _seenIds.remove(_seenIds.keys.first);
    return true;
  }

  /// At most once a second while the page is open, and only with someone to
  /// report. These lines are the measurement `ProximityTracker.bumpRssi` is
  /// waiting for.
  void _logReading(ProximityReading r, DateTime now) {
    final hex = r.closest;
    if (hex == null) return;
    final last = _lastLog;
    if (last != null && now.difference(last) < _logEvery) return;
    _lastLog = now;
    DebugLog.instance.log(
      'BUMP',
      '${_short(hex)} ${r.closestRssi} dBm, '
          'next ${r.runnerUpRssi ?? '-'}${r.isClose ? ' CLOSE' : ''}',
    );
  }

  Uint8List _newId() => Uint8List.fromList(
        List<int>.generate(nearbyIdLen, (_) => _random.nextInt(256)),
      );

  static String _short(String hex) =>
      hex.length > 8 ? hex.substring(0, 8) : hex;
}

final bumpControllerProvider =
    NotifierProvider<BumpController, BumpState>(BumpController.new);
