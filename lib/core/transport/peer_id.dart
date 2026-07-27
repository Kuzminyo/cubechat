import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The 8-byte routing identifier a frame carries for its origin and its
/// destination — and, since it rotates, the reason a passive listener can no
/// longer stitch a device's traffic into one thread.
///
/// ## What was wrong
///
/// The id used to be `BLAKE2s(x25519_pubkey)[0:8]`, computed once and never
/// changed. Every frame a phone ever sent carried the same eight bytes, so
/// anyone recording the air could group a week of traffic by device without
/// breaking a single cipher, and could tell "this is the same person as
/// yesterday" across BLE address rotations that exist precisely to prevent
/// that.
///
/// ## What it is now
///
/// ```
///   id(pubkey, epoch) = BLAKE2s("cubechat/peer-id/v1" ‖ pubkey ‖ epoch_be64)[0:8]
///   epoch             = unix_millis ~/ rotationPeriod
/// ```
///
/// The id is still deterministic — anyone who holds the peer's public key can
/// recompute it, which is what lets a recipient recognise mail addressed to
/// them and a sender address mail to a contact, with no negotiation and no
/// state. But it is only stable for one [rotationPeriod], and an observer who
/// does *not* hold the key sees an unrelated eight bytes each period.
///
/// ## The honest limit
///
/// This is worth exactly as much as the secrecy of the public key it is derived
/// from. A cleartext announcement carrying a static pubkey hands every listener
/// the ability to recompute these ids forever, which is why rotation only means
/// something alongside the private-announcement mode — see
/// `MessagingService._broadcastAnnouncement`. Rotation alone would defend only
/// against a listener who records frames but never parses an announcement.
class PeerId {
  PeerId._();

  /// Length of the routing id, in bytes. Unchanged from the fixed-hash scheme,
  /// so the envelope header keeps its layout.
  static const int len = 8;

  /// How long one id stays valid.
  ///
  /// An hour is chosen against the two windows that bracket it: the
  /// store-and-forward hold and the replay window are both an hour, so a frame
  /// held for its entire life crosses at most one boundary — which
  /// [activeEpochs] already tolerates. Shortening this would start dropping
  /// held mail; lengthening it buys an observer a longer thread to pull on.
  static const Duration rotationPeriod = Duration(hours: 1);

  static const String _domain = 'cubechat/peer-id/v1';

  static final _blake2s = Blake2s();

  /// Which epoch a wall-clock instant falls in.
  static int epochAt(DateTime t) =>
      t.millisecondsSinceEpoch ~/ rotationPeriod.inMilliseconds;

  /// The epochs a receiver must be willing to recognise right now: the current
  /// one, the previous one, and the next.
  ///
  /// The neighbours are not paranoia. A frame minted just before a boundary and
  /// delivered just after — the ordinary case for anything held in
  /// store-and-forward, or sat in a relay's backlog — arrives bearing the
  /// previous epoch's id. And phones are not NTP-synced, so a peer whose clock
  /// runs a few minutes fast addresses us in the next epoch before we have
  /// entered it. Refusing either would look exactly like a lost message.
  static List<int> activeEpochs(DateTime now) {
    final e = epochAt(now);
    return [e - 1, e, e + 1];
  }

  /// The routing id for [pubkey] during [epoch].
  static Future<Uint8List> derive(Uint8List pubkey, int epoch) async {
    final domain = utf8.encode(_domain);
    final input = Uint8List(domain.length + pubkey.length + 8);
    var c = 0;
    input.setRange(c, c += domain.length, domain);
    input.setRange(c, c += pubkey.length, pubkey);
    // Big-endian epoch, so the encoding is unambiguous across platforms and
    // the low bits — the ones that actually change — land at the end.
    final view = ByteData.sublistView(input, c, c + 8);
    view.setUint64(0, epoch, Endian.big);
    final digest = await _blake2s.hash(input);
    return Uint8List.fromList(digest.bytes.sublist(0, len));
  }

  /// Every id [pubkey] may legitimately be wearing right now.
  static Future<List<Uint8List>> deriveActive(
    Uint8List pubkey,
    DateTime now,
  ) async {
    final out = <Uint8List>[];
    for (final epoch in activeEpochs(now)) {
      out.add(await derive(pubkey, epoch));
    }
    return out;
  }

  /// The pre-rotation identifier: `BLAKE2s(pubkey)[0:8]`, fixed for the life of
  /// the identity.
  ///
  /// Kept only so a build that already rotates can still *receive* from one
  /// that doesn't, which is what makes a staggered rollout survivable — during
  /// the changeover the two halves of a conversation are running different
  /// code. Nothing mints these any more.
  static Future<Uint8List> legacy(Uint8List pubkey) async {
    final digest = await _blake2s.hash(pubkey);
    return Uint8List.fromList(digest.bytes.sublist(0, len));
  }

  /// Lowercase hex, the form the lookup tables are keyed on.
  static String hex(Uint8List id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Reverse lookup from a routing id back to the peer wearing it.
///
/// With a fixed id this was a linear scan that hashed every roster entry on
/// every inbound frame; with rotation the same scan would cost four hashes per
/// peer per frame, and inbound frames arrive dozens per second during a media
/// transfer. So the mapping is built once and reused.
///
/// Validity is decided by two things, both cheap to check: the epoch, and
/// whether the roster object is still the same instance. The roster lives in a
/// Riverpod notifier that replaces its map on every change, so an identity
/// comparison is an exact "has anything about the peers changed" test — no
/// version counters to keep in sync.
class PeerIdIndex {
  final Map<String, Uint8List> _byId = {};
  Object? _rosterToken;
  int _epoch = -1;

  /// The peer pubkey behind [id], or null when no known peer answers to it.
  ///
  /// [rosterToken] is any object whose identity changes when the roster does —
  /// in practice the roster map itself.
  Future<Uint8List?> lookup(
    Uint8List id, {
    required Object rosterToken,
    required Iterable<Uint8List> pubkeys,
    DateTime? clock,
  }) async {
    final now = clock ?? DateTime.now();
    final epoch = PeerId.epochAt(now);
    if (epoch != _epoch || !identical(rosterToken, _rosterToken)) {
      await _rebuild(pubkeys, now);
      _epoch = epoch;
      _rosterToken = rosterToken;
    }
    return _byId[PeerId.hex(id)];
  }

  Future<void> _rebuild(Iterable<Uint8List> pubkeys, DateTime now) async {
    _byId.clear();
    for (final pub in pubkeys) {
      for (final id in await PeerId.deriveActive(pub, now)) {
        _byId[PeerId.hex(id)] = pub;
      }
      // Legacy id too, so a peer still running the fixed-hash build resolves.
      _byId[PeerId.hex(await PeerId.legacy(pub))] = pub;
    }
  }

  /// Forget everything — used by the wipe path, and by tests.
  void clear() {
    _byId.clear();
    _rosterToken = null;
    _epoch = -1;
  }
}
