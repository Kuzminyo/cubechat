import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/nickname_controller.dart';
import '../../../core/transport/announcement.dart';
import '../../../core/transport/chat_session_manager.dart';
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

/// Dials a phone held close that has no session yet, the way a tap on its
/// row in Nearby would; the pubkey of whoever answered once the handshake is
/// done, or null. [hex] is null for a phone the scan cannot name. Injectable
/// for tests.
///
/// Build 1109 only ever bumped a phone that already had a session, and only a
/// tap in Nearby or "Connect" in a chat dials one — so two strangers on the
/// AirDrop page glowed, faded and never bumped. Being discoverable only lets
/// a phone *answer* a handshake; somebody has to ring.
///
/// The AirDrop people sheet rings through this too, when somebody without a
/// session is tapped — one dialler, not a copy per entry point.
final bumpDialProvider =
    Provider<Future<String?> Function(String device, String? hex)>(
  (ref) => (device, hex) async {
    final messaging = ref.read(messagingServiceProvider);
    if (hex != null && messaging.hasSessionWithPubkey(hex)) return hex;
    final discovery = ref.read(peerDiscoveryControllerProvider.notifier);
    var address = device;
    if (!messaging.hasLinkOrPendingTo(device)) {
      address = (hex == null ? null : discovery.addressOf(hex)) ?? device;
      // Two attempts, not the tap's four: the gesture dials again on its own
      // ten seconds later if the phones are still together, and a long retry
      // loop would outlive the moment of the bump.
      await messaging.connectAsInitiatorWithRetry(
        deviceId: address,
        displayName: hex == null
            ? NicknameController.defaultNickname
            : ref.read(airdropPeerNameProvider)(hex),
        refreshId: hex == null ? null : () => discovery.awaitAddressOf(hex),
        attempts: 2,
      );
    }
    // The GATT link is up; the Noise handshake finishes a moment later.
    final until = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(until)) {
      final s = ref.read(chatSessionManagerProvider)[address];
      if (s != null && s.isEstablished) return s.remotePubkeyHex;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  },
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
/// held close it is dialled (see [bumpDialProvider]), and a louder one must
/// still stop a quieter named phone from counting as the one touching.
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

  /// A phone with no session is dialled once it gives [_dialSamples] readings
  /// at [dialRssi] or louder inside the tracker's one-second window — ten dB
  /// short of a bump, so the handshake is under way while the phones are
  /// still closing in — and at most once per device per [dialEvery].
  /// [dialEvery] is also how long a dialled phone counts for the glow.
  static const int dialRssi = -50;
  static const int _dialSamples = ProximityTracker.minCloseSamples;
  static const Duration dialEvery = Duration(seconds: 10);

  /// Smallest warmth step the glow is moved by. The warmth spans the 20 dB
  /// from `glowRssi` to `bumpRssi`, so a twentieth was one decibel — the
  /// wobble of a phone lying still — and 1109's glow re-animated on almost
  /// every tick. A tenth is 2 dB of hysteresis.
  static const double _warmthStep = 0.1;

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

  /// Key → the device its newest reading came from: what a dial rings.
  final Map<String, String> _deviceOfKey = {};

  /// Device → when it was last dialled — see [dialEvery].
  final Map<String, DateTime> _dialledAt = {};

  /// Device → the pubkey a dial found behind it. The scan names a phone only
  /// once its rotating id resolves against the roster, which can take a scan
  /// window or two after the handshake; until then its readings are filed
  /// under the identity the handshake proved.
  final Map<String, String> _identityOfDevice = {};

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

  /// What the last BUMP line said — see [_logReading].
  String? _loggedClosest;
  bool _loggedClose = false;

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
    _deviceOfKey.clear();
    _identityOfDevice.clear();
    _loggedClosest = null;
    _loggedClose = false;
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
      final key = r.hex.startsWith(bumpAnonPrefix)
          ? (_identityOfDevice[r.device] ?? r.hex)
          : r.hex;
      // A phone read as `anon:` a moment ago and named now is one phone, not
      // two. Its anonymous readings would otherwise be held for the tracker's
      // three seconds at the very same RSSI — a runner-up zero dB behind that
      // fails the margin, so the phone blocked its own bump right after it
      // resolved (and again after every rotating-id epoch change).
      final before = _keyOfDevice[r.device];
      if (before != null &&
          before != key &&
          before.startsWith(bumpAnonPrefix)) {
        _tracker.forget(before);
        _fed.remove(before);
        _deviceOfKey.remove(before);
      }
      _keyOfDevice[r.device] = key;
      _deviceOfKey[key] = r.device;
      final last = _fed[key];
      if (last != null && !r.seen.isAfter(last)) continue;
      _fed[key] = r.seen;
      sample(key, r.rssi);
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

  /// Emergency wipe: the card on screen goes, and so does everything the
  /// gesture remembers about who was near — pauses, heard bumps, dialled
  /// devices and the identities found behind them. A page still open keeps
  /// running, as from a fresh visit.
  void wipe() {
    _quietUntil.clear();
    _seenIds.clear();
    _dialledAt.clear();
    _tracker.clear();
    _fed.clear();
    _keyOfDevice.clear();
    _deviceOfKey.clear();
    _identityOfDevice.clear();
    _sentAt.clear();
    _heard.clear();
    _sending.clear();
    _loggedClosest = null;
    _loggedClose = false;
    _ownCard = null;
    _visit++;
    state = const BumpState();
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
    final hex = r.closest;
    final bumpable =
        hex != null && ref.read(bumpDirectPeersProvider).contains(hex);
    if (hex != null && !bumpable) _maybeDial(hex, now);
    // The glow promises a bump. Lit for every phone in range, it shone for
    // strangers that — before they were dialled — could never bump at all.
    final w = bumpable || (hex != null && _dialling(hex, now)) ? r.warmth : 0.0;
    // The two ends always land, or a glow could stay lit at 0.05 after the
    // person walked away.
    if (w != state.warmth &&
        ((w - state.warmth).abs() >= _warmthStep - 1e-9 || w == 0 || w == 1)) {
      state = BumpState(warmth: w, event: state.event);
    }
    _logReading(r, now, bumpable: bumpable);
    if (!r.isClose || hex == null || _quiet(hex, now)) return;
    if (!bumpable) return;
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

  String? _deviceOf(String key) => key.startsWith(bumpAnonPrefix)
      ? key.substring(bumpAnonPrefix.length)
      : _deviceOfKey[key];

  bool _dialling(String key, DateTime now) {
    final device = _deviceOf(key);
    final at = device == null ? null : _dialledAt[device];
    return at != null && now.difference(at) < dialEvery;
  }

  /// Rings [key]'s phone when it is held close and nobody is talking to it —
  /// see [bumpDialProvider].
  void _maybeDial(String key, DateTime now) {
    final device = _deviceOf(key);
    if (device == null) return;
    if (_tracker.loudSamples(key, dialRssi, now) < _dialSamples) return;
    if (_dialling(key, now)) return;
    _dialledAt.removeWhere((_, at) => now.difference(at) >= dialEvery);
    _dialledAt[device] = now;
    final named = !key.startsWith(bumpAnonPrefix);
    DebugLog.instance.log('BUMP', 'dialling ${_short(key)}');
    final visit = _visit;
    unawaited(() async {
      try {
        final who =
            await ref.read(bumpDialProvider)(device, named ? key : null);
        if (who == null || _tick == null || visit != _visit) return;
        _identityOfDevice[device] = who;
      } catch (e) {
        DebugLog.instance.log('BUMP', 'dialling ${_short(key)} failed: $e');
      }
    }());
  }

  /// Never throws: a bumped offer awaits it.
  Future<void> _sendBump(String hex) async {
    final port = ref.read(airdropPortProvider);
    final hasFiles =
        vetAirDropFiles(ref.read(airdropStagedProvider)).files.isNotEmpty;
    final card = _ownCard ??= _loadCard();
    try {
      final ok = await port.send(
        hex,
        bump:
            NearbyBump(bumpId: _newId(), hasFiles: hasFiles, card: await card),
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
    // Staging is vetted when it is set; this is for anything that sets it
    // some other way. A file over the cap sends nothing at all, and the bump
    // goes on as if nothing were staged.
    final vetted = vetAirDropFiles(staged);
    if (vetted.tooLarge != null) {
      DebugLog.instance.log(
        'BUMP',
        'not sending to ${_short(hex)}: "${vetted.tooLarge!.name}" too large',
      );
    }
    if (vetted.files.isNotEmpty) {
      _show(BumpSentFiles(hex, name, now, vetted.files.length));
      unawaited(
        _offer(hex, name, vetted.files, staged: staged, after: ours),
      );
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
  /// [staged] is the staging [files] came from.
  Future<void> _offer(
    String hex,
    String name,
    List<AirDropSource> files, {
    required List<AirDropSource> staged,
    required Future<void> after,
  }) async {
    final airdrop = ref.read(airdropControllerProvider.notifier);
    final staging = ref.read(airdropStagedProvider.notifier);
    await after;
    try {
      final t = await airdrop.offer(peerHex: hex, peerName: name, files: files);
      if (t == null) {
        DebugLog.instance.log('BUMP', 'offer to ${_short(hex)} did not go');
        return;
      }
      // Only if the person has not picked something else meanwhile.
      if (identical(staging.state, staged)) staging.state = const [];
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

  /// At most once a second while the page is open, and only while the glow
  /// is lit or the closest phone (or whether it is close) has changed. These
  /// lines are the measurement `ProximityTracker.bumpRssi` is waiting for —
  /// but 1109 wrote one a second whenever *anyone* was in range, and
  /// DebugLog's 200 lines were gone in three minutes of standing in a room.
  void _logReading(ProximityReading r, DateTime now, {required bool bumpable}) {
    final hex = r.closest;
    if (hex == null) return;
    final changed = hex != _loggedClosest || r.isClose != _loggedClose;
    if (state.warmth == 0 && !changed) return;
    final last = _lastLog;
    if (last != null && now.difference(last) < _logEvery) return;
    _lastLog = now;
    _loggedClosest = hex;
    _loggedClose = r.isClose;
    // Samples and link say what is missing when a bump does not fire: too few
    // readings in the window at the tracker's own close threshold (a hint —
    // `isClose` itself goes by the window's median and count), or no direct
    // session yet to carry the bump. Adds nothing to how often this is
    // written.
    final loud = _tracker.loudSamples(hex, _tracker.closeRssi, now);
    DebugLog.instance.log(
      'BUMP',
      '${_short(hex)} ${r.closestRssi} dBm, '
          'next ${r.runnerUpRssi ?? '-'}, '
          'samples $loud/${ProximityTracker.minCloseSamples}, '
          'link ${bumpable ? 'ready' : 'waiting'}${r.isClose ? ' CLOSE' : ''}',
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
