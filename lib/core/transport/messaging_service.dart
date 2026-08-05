import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'package:cryptography/cryptography.dart';

import '../../features/channels/data/channel_avatars_controller.dart';
import '../../features/channels/data/channel_controller.dart';
import '../../features/channels/data/channel_descriptions_controller.dart';
import '../../features/channels/data/channel_roster_controller.dart';
import '../../features/channels/models/channel.dart';
import '../../features/chat/data/messages_controller.dart';
import '../../features/chat/data/pinned_controller.dart';
import '../../features/chat/models/message.dart';
import '../../features/files/data/file_transfer_controller.dart';
import '../../features/peers/data/known_peers_controller.dart';
import '../../features/peers/data/peer_avatars_controller.dart';
import '../../features/peers/data/peer_discovery_controller.dart';
import '../../features/peers/data/peripheral_controller.dart';
import '../../features/peers/data/presence_controller.dart';
import '../../features/peers/data/typing_controller.dart';
import '../../features/peers/models/known_peer.dart';
import '../../features/profile/data/discovery_settings_controller.dart';
import '../../features/profile/data/privacy_settings_controller.dart';
import '../../features/profile/data/relay_settings_controller.dart';
import '../ble/ble_constants.dart';
import '../ble/ble_peripheral.dart';
import '../crypto/channel_crypto.dart';
import '../crypto/fs_message.dart';
import '../crypto/identity_service.dart';
import '../crypto/prekey_service.dart';
import '../crypto/sealed_box.dart';
import '../crypto/signed_payload.dart';
import '../crypto/x3dh.dart';
import '../identity/avatar_controller.dart';
import '../identity/nickname_controller.dart';
import '../notifications/notification_service.dart';
import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
import '../util/app_lifecycle.dart';
import '../util/debug_log.dart';
import 'announcement.dart';
import 'ble_gatt_client.dart';
import 'chat_session.dart';
import 'chat_session_manager.dart';
import 'contact_card.dart';
import 'dedup_cache.dart';
import 'store_forward_cache.dart';
import 'envelope.dart';
import 'frame.dart';
import 'frame_fragment.dart';
import 'file_reassembly.dart';
import 'image_reassembly.dart';
import 'mtu_budget.dart';
import 'inner_payload.dart';
import 'channel_poll.dart';
import 'channel_admin.dart';
import 'peer_id.dart';
import 'nostr/nostr_signer.dart';
import 'nostr/nostr_transport.dart';
import 'nostr/relay_watermark_store.dart';
import 'nostr/websocket_relay_client.dart';
import '../crypto/media_fs_cipher.dart';

/// Wall-clock deadline for the full Noise XX exchange — initiator + responder
/// together. If a session is still handshaking after this, we tear it down and
/// surface a failed state to the UI so the user can retry instead of staring
/// at a "secure channel forming" spinner indefinitely.
const _handshakeTimeout = Duration(seconds: 15);

/// How often we re-broadcast our (pubkey, nickname) announcement on every
/// active link.
///
/// This is a *safety net*, not the delivery mechanism. Everything that makes an
/// announcement worth hearing is pushed the moment it happens: a freshly
/// established session gets one immediately, and so does a rename (see
/// [announceNow]). The periodic copy only exists to re-sync a peer that joined
/// the mesh indirectly, over a hop we never saw come up.
///
/// It used to run every 60 s, which is expensive in a way that is easy to miss:
/// each tick signs an Ed25519 announcement here and makes every peer on every
/// link *verify* one, plus the BLE airtime to carry it. Two links meant that
/// bill twice a minute, forever, on a phone that is doing nothing. As a
/// heartbeat behind two event-driven paths, minutes are plenty.
const _announcementInterval = Duration(minutes: 5);

/// Gap between consecutive publishes when one logical send fans out to many
/// peers over the relays (a presence sweep, a channel post).
///
/// Public relays rate-limit per connection, and they do it bluntly: damus
/// answers a burst with `rate-limited: you are noting too much` and drops the
/// events — including whatever real message was in the same burst. Pacing costs
/// a fraction of a second across a full fan-out and keeps us under that.
const Duration relayFanoutPacing = Duration(milliseconds: 60);

/// Replay window for signed frames. A frame whose signed timestamp is older
/// than this is rejected. It is deliberately aligned with the dedup-cache
/// TTL and the store-and-forward hold time (all 1 hour): a held frame is
/// delivered carrying its original signed timestamp, so the window must be
/// at least as long as we're willing to hold it, and the dedup TTL must
/// cover the same span so replays inside the window are still caught.
const int _replayMaxAgeMs = 60 * 60 * 1000;

/// How far a signed timestamp may sit in the future before we treat it as a
/// bogus / skewed clock and drop the frame. Phones aren't NTP-synced, so we
/// allow a couple of minutes of forward skew.
const int _replayMaxFutureMs = 2 * 60 * 1000;

class MediaRouteUnavailable implements Exception {
  const MediaRouteUnavailable();
}

/// Top-level orchestrator that ties BLE, Noise sessions, and the in-memory
/// message store together.
///
/// Two flows:
///
/// **Outbound (we tap a peer in the Nearby list):**
///   1. Caller asks [connectAsInitiator] with a BluetoothDevice
///   2. We open a [BleGattClient], start a [ChatSession] as initiator, and
///      send Noise XX message 1 over the outbound characteristic
///   3. Peer replies on the inbound (notify) characteristic with HS2 → we
///      send HS3 → handshake established → status = established
///   4. Any subsequent encryptText() goes over outbound as a transport frame
///
/// **Inbound (a central connects to our peripheral and starts a handshake):**
///   1. Peripheral plugin fires a PeripheralEvent.write with HS1
///   2. We start a [ChatSession] as responder, drive the handshake by
///      pushing HS2 / HS3 back via [BlePeripheral.notifyInbound]
///   3. Subsequent writes carry transport frames → we decrypt and append
///      to [MessagesController]
class MessagingService {
  MessagingService(this._ref) {
    _wirePeripheralEvents();
    _startAnnouncementTimer();
    _startPresenceTimer();
    _startFileQueueTimer();
    _wireNostrFallback();
    _startInBackground('relay buffer', _loadRelayBuffer());
    _startInBackground(
      'prekeys',
      _ref.read(prekeyServiceProvider).ensureInitialized(),
    );
  }

  /// Kick off initialisation the constructor cannot await, absorbing failure.
  ///
  /// `unawaited` silences the lint but does not handle anything: a future that
  /// completes with an error still lands in the surrounding zone with nobody to
  /// receive it. Both callers here open Hive boxes, which fail for reasons
  /// outside this class — a keystore reset, a storage directory that went away
  /// underneath us — and neither is worth taking the app down for. The relay
  /// buffer is a cache that repopulates, and the prekey is re-minted on the
  /// next attempt.
  void _startInBackground(String what, Future<void> work) {
    unawaited(work.catchError((Object e) {
      DebugLog.instance.log('MESH', '$what init failed: $e');
    }));
  }

  /// Envelope-body cipher tags (first byte of [TransportEnvelope.body]) so
  /// the receiver knows how to decrypt before it can look inside.
  static const int _cipherSealedBox = 0x01;
  static const int _cipherX3dh = 0x02;

  /// Channel cipher: the body is `[channelTag:8][ChannelCrypto blob]`, a
  /// broadcast frame encrypted under a shared group key. See [ChannelCrypto].
  static const int _cipherChannel = 0x03;

  /// Forward-secret media chunk: the body is a [MediaFsCipher] blob sealed
  /// under a per-transfer X3DH key. The key is derived from the sender pubs in
  /// the (v0x02) [MediaManifest], which is sent first. See [MediaFsCipher].
  static const int _cipherX3dhMedia = 0x04;

  /// Cap on FS chunks we'll hold for a single transfer whose manifest hasn't
  /// arrived yet — bounds memory against a peer that streams chunks and never
  /// sends the manifest.
  static const int _maxPendingFsChunks = 8192;

  final Ref _ref;

  /// Set by [dispose] so async teardown steps know the container is on its way
  /// out and must not be read from.
  bool _disposed = false;
  final _clients = <String, BleGattClient>{}; // central-side clients
  final _handshakeTimers = <String, Timer>{}; // peerId -> watchdog timer
  StreamSubscription<PeripheralEvent>? _peripheralEventsSub;
  Timer? _announcementTimer;
  Timer? _presenceTimer;
  Timer? _fileQueueTimer;
  bool _drainingFileQueue = false;

  /// Our rotating routing id, cached per epoch. See [PeerId] for why it moves
  /// and [_myPubkeyHash] for how far back the cache is kept.
  final Map<int, Uint8List> _myIdByEpoch = {};

  /// Reverse index from a routing id to the peer wearing it, rebuilt when the
  /// epoch turns or the roster changes.
  final PeerIdIndex _peerIds = PeerIdIndex();

  /// Our deterministically-derived Nostr signer (secp256k1). Derivation does a
  /// scalar multiplication, so we compute it once and reuse it for every
  /// announcement and (later) off-mesh send.
  Secp256k1NostrSigner? _nostrSignerCache;

  /// Drops duplicate transport frames (a frame we've already seen or
  /// forwarded) before they hit the chat UI or the relay path. Keyed on
  /// (origin, msgId). TTL is aligned with the replay window so a frame
  /// re-injected anywhere inside that window is still recognised as a
  /// duplicate; capacity is generous enough for a busy event mesh.
  final DedupCache _dedup =
      DedupCache(capacity: 4096, ttl: const Duration(hours: 1));

  /// Opportunistic store-and-forward buffer: encrypted frames held for peers
  /// that aren't reachable right now, flushed when they next connect to us.
  final StoreForwardCache _store = StoreForwardCache();

  /// Reassembles [FrameType.fragment] frames back into whole frames before
  /// dispatch. A frame too big for a link's negotiated MTU is split on the way
  /// out (see [_writeFrameToClient] / [_notifyFrameToPeripheral] /
  /// [_fanoutAllLinks]) and rejoined here — the fix for FS-text and media that
  /// were being truncated on low-MTU iOS↔Android links.
  final FrameFragmentReassembler _fragments = FrameFragmentReassembler();

  /// Our own outgoing messages that were queued because the recipient was
  /// unreachable. Keyed by the envelope msgId hex so the flush path can flip
  /// the chat-bubble status to "delivered" once the frame is actually handed
  /// over. In-memory only: a restart loses the status link (the frame still
  /// gets delivered from the persisted relay buffer, the checkmark just
  /// won't update for that older message).
  final Map<String, _OutboxRef> _outbox = {};

  /// Transport wireIds (hex) we've already sent a read receipt for, so
  /// re-opening a chat doesn't re-ack the same backlog every time. In-memory
  /// only — a restart may re-send one receipt per message, which the receiver
  /// applies idempotently.
  final Set<String> _sentReadAcks = {};

  /// Encrypted Hive box backing [_store] so held frames survive an app
  /// restart (within the 1h TTL). Writes are debounced via
  /// [_relayPersistTimer] so a media-relay burst doesn't thrash the disk.
  Box<List<dynamic>>? _relayBox;
  Timer? _relayPersistTimer;

  /// Multi-chunk image reassembly buffer (M5.4). Each incoming image stream
  /// is keyed by its 16-byte imageId; finished images get written to the
  /// app cache directory and surfaced as Message.kind == image.
  final ImageReassembler _imageReassembler = ImageReassembler();

  /// Mirror of [_imageReassembler] for voice messages.
  final AudioReassembler _audioReassembler = AudioReassembler();

  /// Files are put back together on disk rather than in memory: a photo capped
  /// at a few hundred kilobytes can live in RAM, twenty-five megabytes of
  /// someone else's upload cannot. Created lazily because it needs the
  /// platform's temp directory.
  FileReassembler? _fileReassembler;

  Future<FileReassembler> _files() async {
    final existing = _fileReassembler;
    if (existing != null) return existing;
    final tmp = await getTemporaryDirectory();
    final made = FileReassembler(
      workDir: Directory('${tmp.path}${Platform.pathSeparator}cubechat-files'),
    );
    return _fileReassembler = made;
  }

  /// Verified signed [MediaManifest]s waiting for their chunk stream to
  /// finish reassembling. Keyed by mediaId hex. GC'd after [_manifestTtl].
  final Map<String, _ManifestEntry> _pendingManifests = {};

  /// Assembled media bytes whose manifest hasn't arrived yet. Same key
  /// space as [_pendingManifests]; whichever side lands second triggers
  /// the SHA-256 verification + delivery.
  final Map<String, _OrphanMedia> _orphanedMedia = {};

  /// Per-transfer X3DH keys for inbound forward-secret media, keyed by
  /// mediaId hex. Populated when a v0x02 [MediaManifest] arrives; consumed by
  /// the [_cipherX3dhMedia] chunk-decrypt path. GC'd with the other buffers.
  final Map<String, SecretKey> _mediaKeys = {};

  /// FS media chunks that arrived before their manifest (so before we could
  /// derive the key). Keyed by mediaId hex; flushed once the manifest lands.
  final Map<String, List<_PendingFsChunk>> _pendingFsChunks = {};

  /// How long we keep waiting for a manifest or for the missing
  /// chunks before garbage-collecting the half-finished transfer.
  static const Duration _manifestTtl = Duration(minutes: 5);
  static const int _maxPendingMediaManifests = 64;

  /// Our routing id for the current epoch — stamped on everything we
  /// originate, and rotating out from under a passive listener every
  /// [PeerId.rotationPeriod]. Cached per epoch, with anything stale enough to
  /// be outside the acceptance window dropped.
  Future<Uint8List> _myPubkeyHash() async {
    final epoch = PeerId.epochAt(DateTime.now());
    final cached = _myIdByEpoch[epoch];
    if (cached != null) return cached;
    final id = await _ref.read(identityProvider.future);
    final derived =
        await PeerId.derive(Uint8List.fromList(id.publicKey), epoch);
    _myIdByEpoch
      ..removeWhere((e, _) => (epoch - e).abs() > 1)
      ..[epoch] = derived;
    return derived;
  }

  /// The id that addresses [peerPubkey] right now.
  Future<Uint8List> _peerPubkeyHash(Uint8List peerPubkey) =>
      PeerId.derive(peerPubkey, PeerId.epochAt(DateTime.now()));

  /// Every id a frame could legitimately be using to address *us* — the three
  /// live epochs, plus the pre-rotation fixed hash so a peer still running an
  /// older build can be heard during a staggered rollout.
  Future<List<Uint8List>> _myInboundIds() async {
    final identity = await _ref.read(identityProvider.future);
    final pub = Uint8List.fromList(identity.publicKey);
    return [
      ...await PeerId.deriveActive(pub, DateTime.now()),
      await PeerId.legacy(pub),
    ];
  }

  /// Whether [destHash] addresses us under any currently-valid id.
  Future<bool> _isAddressedToMe(Uint8List destHash) async {
    for (final id in await _myInboundIds()) {
      if (_bytesEqual(destHash, id)) return true;
    }
    return false;
  }

  /// Resolve an origin/dest id back to the peer's canonical X25519 pubkey,
  /// across every epoch they might have used.
  Future<Uint8List?> _peerForId(Uint8List id) async {
    final roster = _ref.read(knownPeersControllerProvider);
    final pubkeys = <Uint8List>[];
    for (final p in roster.values) {
      try {
        pubkeys.add(_hexDecodeBytes(p.pubkeyHex));
      } catch (_) {
        // malformed roster entry — skip
      }
    }
    return _peerIds.lookup(id, rosterToken: roster, pubkeys: pubkeys);
  }

  /// Lazily derive (and cache) our Nostr signer from the Ed25519 identity seed.
  Future<Secp256k1NostrSigner> _myNostrSigner() async {
    if (_nostrSignerCache != null) return _nostrSignerCache!;
    final id = await _ref.read(identityProvider.future);
    _nostrSignerCache = await Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(id.signPrivateKey),
    );
    return _nostrSignerCache!;
  }

  // --------------------------- Nostr fallback (M6) ---------------------------

  /// Live relay pool + transport, non-null only while the user has the Nostr
  /// fallback switched on with at least one relay configured.
  WebSocketNostrRelayClient? _relayClient;
  NostrTransport? _nostr;
  StreamSubscription<Uint8List>? _nostrSub;
  StreamSubscription<Map<String, RelayState>>? _relayStateSub;

  /// Where the relay subscription resumes from across restarts.
  final RelayWatermarkStore _relayWatermark = RelayWatermarkStore();

  /// Guards against two [_applyRelaySettings] runs interleaving (the user
  /// toggling fast, or a settings write landing while we're still connecting)
  /// and leaving a stray socket pool behind.
  Future<void> _nostrReconfigure = Future<void>.value();

  /// Rebuild the Nostr transport whenever the relay settings change, and once
  /// at startup for the persisted value.
  void _wireNostrFallback() {
    _ref.listen<RelaySettings>(
      relaySettingsProvider,
      (_, next) => _nostrReconfigure =
          _nostrReconfigure.then((_) => _applyRelaySettings(next)),
      fireImmediately: true,
    );
  }

  /// Tear down the current pool and, if the fallback is on, stand up a new one
  /// subscribed to our own Nostr pubkey. Inbound events are unwrapped back into
  /// plain frame bytes and pushed through the same dispatch a BLE notify uses,
  /// so a relay-delivered message is indistinguishable downstream (and gets the
  /// same dedup, replay-window and signature checks).
  Future<void> _applyRelaySettings(RelaySettings settings) async {
    await _teardownNostr();
    if (!settings.isActive) {
      DebugLog.instance.log('NOSTR', 'internet fallback off');
      return;
    }
    try {
      final signer = await _myNostrSigner();
      // Resume the subscription from the last event we accepted. Without this a
      // relaunch asks for everything the relays still hold and re-delivers the
      // entire off-mesh history (dedup then drops it, but we'd pay for the
      // download and the decrypt every time).
      final since = await _relayWatermark.load();
      final client = WebSocketNostrRelayClient(
        relayUrls: settings.urls,
        sinceSeconds: since,
        onWatermark: (seconds) => unawaited(_relayWatermark.save(seconds)),
      );
      final transport = NostrTransport(signer: signer, relay: client);
      _relayClient = client;
      _nostr = transport;
      _nostrSub = transport.inboundFrames().listen(
            (bytes) => unawaited(_handleInboundBytes(_nostrPeerId, bytes)),
            onError: (Object e) =>
                DebugLog.instance.log('NOSTR', 'inbound stream error: $e'),
          );
      _relayStateSub = client.stateChanges.listen(
        (states) => _ref.read(relayStatusProvider.notifier).publish(states),
      );
      client.start();
      _ref.read(relayStatusProvider.notifier).publish(client.states);
      DebugLog.instance.log(
          'NOSTR',
          'internet fallback on — ${settings.urls.length} relay(s), '
              'listening as ${signer.npubHex.substring(0, 12)}…');
    } catch (e) {
      DebugLog.instance.log('NOSTR', 'failed to start relay transport: $e');
      await _teardownNostr();
    }
  }

  Future<void> _teardownNostr() async {
    await _nostrSub?.cancel();
    _nostrSub = null;
    await _relayStateSub?.cancel();
    _relayStateSub = null;
    _nostr = null;
    final client = _relayClient;
    _relayClient = null;
    await client?.dispose();
    // Only meaningful while the app is still running: this publishes "no
    // relays" to the UI. On our own disposal the container is already going
    // down, and reading a provider out of it here throws.
    if (!_disposed) _ref.read(relayStatusProvider.notifier).clear();
  }

  /// Synthetic peerId for frames that arrived over a relay rather than a BLE
  /// link. It never matches a [ChatSession] key, which is exactly right: a
  /// relay frame carries no Noise session, and the transport envelope inside is
  /// decrypted with our identity keys either way. It also can't collide with a
  /// BLE peerId, so the relay path never gets excluded from mesh re-forwarding.
  static const String _nostrPeerId = 'nostr:relay';

  /// Last-resort delivery for a frame the mesh couldn't carry: publish it to
  /// the peer's Nostr pubkey. Returns false (never throws) when the fallback is
  /// off, we don't know the peer's npub, or no relay accepted the event — the
  /// caller then falls through to store-and-forward exactly as before.
  Future<bool> _sendOverNostr(String canonicalId, Uint8List frameBytes) async {
    final transport = _nostr;
    if (transport == null) return false;
    // With every socket down there is nothing to try: publish would throw "no
    // relay connected" for each peer in turn, and the caller falls through to
    // store-and-forward either way. Asking first is not an optimisation — a
    // phone with no internet ran the 45 s presence heartbeat against its whole
    // roster and wrote two failure lines per peer per beacon, which is what
    // buried the log.
    if (_relayClient?.isConnected != true) return false;
    final npub =
        _ref.read(knownPeersControllerProvider)[canonicalId]?.nostrPubkey;
    if (npub == null || npub.length != 32) {
      DebugLog.instance.log(
          'NOSTR', 'no npub for $canonicalId — cannot use internet fallback');
      return false;
    }
    final npubHex = _hexOf(npub);
    try {
      // Make sure they know who we are before the payload lands (see
      // [_announceOverNostrTo]); harmless no-op after the first time.
      await _announceOverNostrTo(npubHex, _hexDecodeBytes(canonicalId));
      final receipt = await transport.sendFrame(
        recipientNpubHex: npubHex,
        frameBytes: frameBytes,
      );
      // A write is not a send. Relays refuse events routinely — rate limits,
      // size caps, spam heuristics — and counting a refusal as delivery is how
      // a message disappears while the chat shows it delivered. A relay that
      // simply went quiet is treated as acceptance: the event has most likely
      // been stored, and falling back to store-and-forward for silence would
      // strand messages behind one slow relay.
      if (receipt.isRefused) {
        DebugLog.instance.log(
            'NOSTR',
            'every relay refused the frame for $canonicalId '
                '(${receipt.rejections.join('; ')})');
        return false;
      }
      DebugLog.instance.log('NOSTR',
          'sent ${frameBytes.length}B to $canonicalId via relay — $receipt');
      return true;
    } catch (e) {
      DebugLog.instance.log('NOSTR', 'relay send to $canonicalId failed: $e');
      return false;
    }
  }

  /// The peer's Noise static key, if we can tell who is behind [peerId]
  /// *before* handshaking. Null means we cannot, and the caller falls back to
  /// XX.
  ///
  /// This is deliberately narrow, because BLE gives us very little to go on: an
  /// advertisement carries a service UUID and a rotating hardware address, not
  /// an identity, and [DiscoveredPeer.pubkeyFingerprint] is only filled in
  /// *after* a handshake has authenticated the peer. So the two cases that do
  /// resolve are:
  ///
  ///  * a chat opened from the Chats list, where the route id *is* the peer's
  ///    pubkey hex rather than a device id;
  ///  * a device whose advertised rotating id the discovery layer resolved back
  ///    to somebody in the roster — the case that used to be impossible, and
  ///    the reason the id is advertised at all;
  ///  * a reconnect to a device we already authenticated in this run, where the
  ///    old session still remembers the key.
  ///
  /// A stranger resolves to none of these, so they get XX — which is correct:
  /// there is no way to address IK at someone you have never met.
  Uint8List? _knownStaticFor(String displayName, String peerId) {
    // The Chats list routes by pubkey hex; Nearby routes by device id.
    if (peerId.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(peerId)) {
      try {
        return _hexDecodeBytes(peerId);
      } catch (_) {
        // Not hex after all — fall through.
      }
    }
    // A contact recognised from their advertisement.
    for (final p in _ref.read(peerDiscoveryControllerProvider).peers) {
      if (p.id != peerId) continue;
      final hex = p.resolvedPubkeyHex;
      if (hex == null) break;
      try {
        return _hexDecodeBytes(hex);
      } catch (_) {
        break;
      }
    }
    final prior = _ref.read(chatSessionManagerProvider)[peerId];
    return prior?.remoteStaticPublicKey;
  }

  /// Marks an announcement body as `[0x01][SealedBox blob]` rather than a bare
  /// signed announcement. Only ever used off-mesh — see [_announceOverNostrTo]
  /// for why a relay introduction must not be readable by the relay, and
  /// [_handlePeerAnnouncementFrame] for the unwrap.
  static const int _announcementSealed = 0x01;

  /// Nostr pubkeys we've already introduced ourselves to in this process.
  ///
  /// In-memory on purpose: an extra announcement after a restart costs one
  /// event and is idempotent on the receiver (the roster upsert is a no-op when
  /// nothing changed), whereas a persisted "already done" flag that went stale —
  /// after a nickname change, a prekey rotation, or a wipe-and-reinstall on
  /// their side — would leave the peer permanently unable to reach us.
  final Set<String> _announcedOverNostr = {};

  /// Publish our signed announcement to a single peer's Nostr pubkey.
  ///
  /// This is what makes a *cold* internet conversation possible. A contact card
  /// only travels one way: they handed us their keys, so we can encrypt to
  /// them, but they hold nothing of ours. An inbound frame carries just an
  /// 8-byte origin hash, which is not enough to reverse into an identity — so
  /// without an introduction our first message would land in their app
  /// unattributable to any chat, and they would have no address to answer at.
  /// Sending the same self-authenticating bundle the mesh broadcasts closes
  /// both gaps at once.
  ///
  /// **Sealed to the recipient.** On the mesh an announcement is a cleartext
  /// broadcast — it has to be, since it's addressed to whoever is in range. A
  /// public relay is a different room: events there are readable by anyone who
  /// asks for them, so publishing the bundle as-is would put a *human-readable
  /// nickname* next to a Nostr pubkey, permanently, for a passive scraper. That
  /// is the one thing every other frame on this path is careful not to leak, so
  /// the introduction is wrapped in a [SealedBox] to the recipient's X25519 key
  /// (which we have — it's what a contact card is for) and tagged
  /// [_announcementSealed]. Plaintext announcements always start with the
  /// version byte 0x04, so the tag can never be mistaken for one.
  ///
  /// Sent with `ttl: 1` — unlike a mesh announcement this is a point-to-point
  /// introduction, and the receiver decrementing 1 to 0 stops it from being
  /// flooded onward across their local Bluetooth neighbourhood (where nobody
  /// could open it anyway).
  Future<void> _announceOverNostrTo(String npubHex, Uint8List peerPub) async {
    final transport = _nostr;
    if (transport == null) return;
    // Same reason as [_sendOverNostr]: with no socket up this can only fail,
    // and it is reached once per peer per beacon. Checked before the
    // already-introduced set so an offline attempt doesn't mark the peer done.
    if (_relayClient?.isConnected != true) return;
    if (!_announcedOverNostr.add(npubHex)) return;
    try {
      final sealed = await SealedBox.seal(
        await buildSignedAnnouncement(),
        peerPub,
      );
      final frame = _announcementFrame(
        signedBody: _tagBody(_announcementSealed, sealed),
        originHash: await _myPubkeyHash(),
        ttl: 1,
      );
      await transport.sendFrame(
        recipientNpubHex: npubHex,
        frameBytes: frame.encode(),
      );
      DebugLog.instance
          .log('NOSTR', 'introduced ourselves to ${npubHex.substring(0, 12)}…');
    } catch (e) {
      // Un-mark so the next send retries; a peer that never receives the
      // introduction can never answer us.
      _announcedOverNostr.remove(npubHex);
      DebugLog.instance.log('NOSTR', 'introduction to $npubHex failed: $e');
    }
  }

  /// Prepend the 1-byte cipher tag to an encrypted body.
  static Uint8List _tagBody(int cipher, Uint8List body) {
    final out = Uint8List(1 + body.length);
    out[0] = cipher;
    out.setRange(1, out.length, body);
    return out;
  }

  /// Build the inner payload for a text send: a plain [InnerPayloadType.text]
  /// or, when [replyTarget] (a 16-byte quoted msgId) is set, an
  /// [InnerPayloadType.textReply]. [bucket] null uses the default text padding
  /// (SealedBox path); pass 0 to skip padding (FS path, to save MTU).
  Uint8List _buildTextInner(
    Uint8List utf8Text,
    Uint8List? replyTarget, {
    int? bucket,
  }) {
    final padded = bucket == null
        ? padTextPayload(utf8Text)
        : padTextPayload(utf8Text, bucket: bucket);
    if (replyTarget == null) {
      return packInnerPayload(InnerPayloadType.text, padded);
    }
    return packInnerPayload(
      InnerPayloadType.textReply,
      packTextReply(replyTarget, padded),
    );
  }

  /// Fresh ephemeral X25519 key pair for one forward-secret send.
  Future<SimpleKeyPairData> _freshEphemeralX25519() async {
    final kp = await X25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    final priv = await kp.extractPrivateKeyBytes();
    return SimpleKeyPairData(priv, publicKey: pub, type: KeyPairType.x25519);
  }

  /// If we hold the recipient's signed prekey, derive a fresh per-transfer
  /// X3DH key + ephemeral so a media stream can be sealed forward-secret
  /// ([MediaFsCipher]). Returns null when FS isn't available (no cached
  /// prekey, or a derivation error) → the caller falls back to SealedBox.
  Future<({SecretKey key, Uint8List identityPub, Uint8List ephemeralPub})?>
      _deriveMediaFsSetup(String canonicalId, Uint8List peerPub) async {
    final recipientSpk =
        _ref.read(knownPeersControllerProvider)[canonicalId]?.signedPrekeyPub;
    if (recipientSpk == null || recipientSpk.length != 32) return null;
    try {
      final identity = await _ref.read(identityProvider.future);
      final ephemeral = await _freshEphemeralX25519();
      final sk = await X3dh.deriveSender(
        identityKeyPair: identity.asKeyPair(),
        ephemeralKeyPair: ephemeral,
        recipientIdentityPub: peerPub,
        recipientSignedPrekeyPub: recipientSpk,
      );
      return (
        key: sk,
        identityPub: Uint8List.fromList(identity.publicKey),
        ephemeralPub: Uint8List.fromList(ephemeral.publicKey.bytes),
      );
    } catch (e) {
      DebugLog.instance
          .log('CRYPTO', 'media FS setup failed ($e) — SealedBox fallback');
      return null;
    }
  }

  /// Tap-to-connect: the user picked a peer in the Nearby list. We're the
  /// initiator. [displayName] is the human-readable label (advertised BLE
  /// name) — we tuck it into the session so the chat list/header has
  /// something readable until the pubkey fingerprint becomes available.
  Future<void> connectAsInitiator(
    BluetoothDevice device, {
    required String displayName,
  }) async {
    final peerId = device.remoteId.str;

    if (_clients.containsKey(peerId)) {
      debugPrint('connectAsInitiator: already connected to $peerId');
      return;
    }

    final client = BleGattClient(device);
    _clients[peerId] = client;

    try {
      await client.connect();
    } catch (e, st) {
      debugPrint('connect to $peerId failed: $e\n$st');
      // Dispose, don't merely drop the reference: connect() subscribes to the
      // device's connectionState before the GATT connect can time out, so a
      // bare remove() leaks that subscription plus the client's two stream
      // controllers on every failed attempt — and the store-and-forward
      // auto-connect retries this path on a timer.
      await _clients.remove(peerId)?.dispose();
      rethrow;
    }

    // Listen for inbound frames on this central connection.
    client.inboundFrames.listen((bytes) => _handleInboundBytes(peerId, bytes));
    client.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _ref.read(chatSessionManagerProvider.notifier).drop(peerId);
        _clients.remove(peerId);
      }
    });

    final manager = _ref.read(chatSessionManagerProvider.notifier);
    // Prefer IK whenever we already hold this peer's static key — from a past
    // handshake, an announcement, or a contact card. It saves a round trip, it
    // spares them re-sending a key we have, and it is the only opener a peer
    // who has switched discovery off will answer at all.
    final knownStatic = _knownStaticFor(displayName, peerId);
    DebugLog.instance.log(
      'NOISE',
      knownStatic == null
          ? 'no known key for $peerId — opening with XX'
          : 'known key for $peerId — opening with IK',
    );
    final session = knownStatic == null
        ? await manager.startInitiator(peerId, peerLabel: displayName)
        : await manager.startInitiatorIk(
            peerId,
            peerLabel: displayName,
            remoteStatic: knownStatic,
          );

    _armHandshakeWatchdog(peerId);

    // Fire HS1.
    final hs1 = await session.nextHandshakeFrame();
    if (hs1 == null) {
      DebugLog.instance.log('NOISE', 'initiator could not produce HS1');
      return;
    }
    DebugLog.instance.log('NOISE', 'TX HS1 (${hs1.payload.length}B payload)');
    await client.writeOutbound(hs1.encode());
    manager.touch(peerId);

    // Surface MTU-too-small immediately — HS2 is ~97B + 1 byte type, so we
    // need ≥ ~100B effective payload. At the 23-byte ATT default that leaves
    // only 20B of usable notify space, so every frame is fragmented and the
    // link crawls. `negotiatedMtu` is read live, so by now it reflects
    // whatever the platform actually settled on, including on iOS.
    final mtu = client.negotiatedMtu;
    if (mtu < 100) {
      DebugLog.instance.log(
          'NOISE',
          'WARNING: MTU=$mtu is too small for handshake frames — '
              'frames will be fragmented and delivery will be slow');
    } else {
      DebugLog.instance.log(
          'NOISE',
          'link MTU=$mtu '
              '(${effectivePayload(mtu)}B usable payload)');
    }
  }

  /// Connect to [deviceId], retrying a bounded number of times.
  ///
  /// A single attempt is unreliable on Android for two independent reasons:
  ///
  ///  * the stack fails the first GATT connect with 133 / 147
  ///    (GATT_CONNECTION_TIMEOUT) far more often than the radio conditions
  ///    warrant, and an immediate second attempt usually succeeds;
  ///  * a peer that rotated its BLE privacy address answers only on its new
  ///    address, so between attempts we ask [refreshId] to re-scan for the
  ///    one it is using now.
  ///
  /// A peer that *does* connect but doesn't expose the cubechat service is a
  /// permanent failure, not a transient one, so it is never retried.
  Future<void> connectAsInitiatorWithRetry({
    required String deviceId,
    required String displayName,
    Future<String?> Function()? refreshId,
    int attempts = 3,
  }) async {
    var id = deviceId;
    Object lastError = StateError('connect was never attempted');

    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        await connectAsInitiator(
          BluetoothDevice.fromId(id),
          displayName: displayName,
        );
        return;
      } on StateError {
        rethrow; // answered, but not a cubechat node — retrying is futile
      } catch (e) {
        lastError = e;
        DebugLog.instance.log('BLE-CENTRAL',
            'connect attempt $attempt/$attempts to $id failed: $e');
      }

      if (attempt == attempts) break;
      await Future<void>.delayed(Duration(milliseconds: 250 * attempt));

      final fresh = await refreshId?.call();
      if (fresh != null && fresh != id) {
        DebugLog.instance.log('BLE-CENTRAL',
            'peer address rotated $id → $fresh — retrying there');
        id = fresh;
      }
    }
    throw lastError;
  }

  /// Starts a one-shot timer that marks the session failed if the handshake
  /// hasn't reached `established` within [_handshakeTimeout]. The timer is
  /// auto-cancelled when [_clearHandshakeWatchdog] fires (which the frame
  /// dispatcher calls on every state advance).
  void _armHandshakeWatchdog(String peerId) {
    _handshakeTimers[peerId]?.cancel();
    _handshakeTimers[peerId] = Timer(_handshakeTimeout, () {
      _handshakeTimers.remove(peerId);
      final manager = _ref.read(chatSessionManagerProvider.notifier);
      final session = manager.sessionFor(peerId);
      if (session == null || session.isEstablished) return;
      DebugLog.instance.log(
          'NOISE', 'handshake TIMEOUT for $peerId (status=${session.status})');
      session.markFailed();
      manager.touch(peerId);
      // Tear down the BLE link so a Retry rebuilds it cleanly.
      _clients.remove(peerId)?.dispose();
    });
  }

  void _clearHandshakeWatchdog(String peerId) {
    _handshakeTimers.remove(peerId)?.cancel();
  }

  /// Send an encrypted text message to [peerId]. Returns the local Message
  /// object that was appended to the store (with `status: sending` initially
  /// and bumped to `delivered` once the BLE write resolves).
  /// Send an encrypted text message. [chatId] is either a BLE transport id
  /// (when the user is in an already-open ChatScreen from a tap on the
  /// Nearby tab) OR a pubkeyHex (when the user re-entered the chat from the
  /// main Chats list or — M3.E — is messaging a mesh-only peer with no direct
  /// session). Resolution order:
  ///   1. live session by transport id
  ///   2. live session by pubkeyHex
  ///   3. KnownPeers entry by pubkeyHex (mesh-only — relayed via all links)
  Future<Message> sendText(
    String chatId,
    String text, {
    String? replyToWireId,
  }) async {
    final manager = _ref.read(chatSessionManagerProvider.notifier);

    ChatSession? session = manager.sessionFor(chatId);
    session ??= _findSessionByPubkeyHex(chatId);

    Uint8List? peerPub;
    String? canonicalId;
    if (session != null && session.isEstablished) {
      peerPub = session.remoteStaticPublicKey;
      canonicalId = session.remotePubkeyHex ?? chatId;
    } else {
      // No direct session — fall back to a mesh send if we know this pubkey
      // from a prior announcement / handshake.
      final known = _ref.read(knownPeersControllerProvider)[chatId];
      if (known != null) {
        try {
          peerPub = _hexDecodeBytes(known.pubkeyHex);
          canonicalId = known.pubkeyHex;
        } catch (e) {
          DebugLog.instance
              .log('MESH', 'sendText: malformed pubkey hex for $chatId: $e');
        }
      }
    }

    if (peerPub == null || canonicalId == null) {
      throw StateError('cannot send: no recipient pubkey for $chatId');
    }

    // A reply quotes an earlier message by its wireId (hex of its 16-byte
    // transport msgId). Ignore a malformed/wrong-length handle rather than
    // failing the send.
    Uint8List? replyTarget;
    if (replyToWireId != null) {
      try {
        final decoded = _hexDecodeBytes(replyToWireId);
        if (decoded.length == replyTargetLen) replyTarget = decoded;
      } catch (_) {}
    }

    // Mint the transport msgId up front so the local Message can record it as
    // its wireId — the stable handle a read receipt / reaction from the peer
    // will reference back.
    final msgId = TransportEnvelope.newMsgId(initialTtl: _meshTtl);
    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: canonicalId,
      text: text,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      wireId: TransportEnvelope.hashHex(msgId),
      replyToWireId: replyTarget != null ? replyToWireId : null,
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);
    // Also append under the transport id if the caller passed one (so an
    // open ChatScreen routed via /chat/<bleId> sees the outgoing message
    // until we migrate it to the pubkey-keyed route).
    if (chatId != canonicalId) {
      messages.append(chatId, msg);
    }

    try {
      final identity = await _ref.read(identityProvider.future);
      final utf8Text = Uint8List.fromList(utf8.encode(text));
      final myHash = await _myPubkeyHash();
      final peerHash = await _peerPubkeyHash(peerPub);
      final ctx = SignedPayload.contextBytes(
        originPubkeyHash: myHash,
        destPubkeyHash: peerHash,
        msgId: msgId,
      );

      // Forward-secrecy path: if we hold the recipient's signed prekey
      // (from their signed announcement) AND the resulting frame fits the
      // BLE MTU, encrypt with an X3DH-derived key + a fresh ephemeral so a
      // later compromise of the recipient's long-term key can't decrypt
      // this message. Otherwise fall back to SealedBox (no FS, but proven
      // and fits longer text). FS uses the compact signature (0xA2) and no
      // length padding to claw back MTU headroom.
      final recipientSpk =
          _ref.read(knownPeersControllerProvider)[canonicalId]?.signedPrekeyPub;
      Uint8List? body;
      if (recipientSpk != null && recipientSpk.length == 32) {
        // Any failure in the FS path MUST fall through to SealedBox — never
        // fail the whole send. (A bug here once silently dropped every
        // message to peers we held a prekey for.)
        try {
          final innerFs = _buildTextInner(utf8Text, replyTarget, bucket: 0);
          final signedFs = await SignedPayload.wrapCompact(
            inner: innerFs,
            context: ctx,
            signKeyPair: identity.asSignKeyPair(),
            senderEdPub: identity.signPublicKey,
          );
          final ephemeral = await _freshEphemeralX25519();
          final sk = await X3dh.deriveSender(
            identityKeyPair: identity.asKeyPair(),
            ephemeralKeyPair: ephemeral,
            recipientIdentityPub: peerPub,
            recipientSignedPrekeyPub: recipientSpk,
          );
          final fsBody = await FsMessage.seal(
            key: sk,
            plaintext: signedFs,
            senderIdentityPub: identity.publicKey,
            senderEphemeralPub: Uint8List.fromList((ephemeral.publicKey).bytes),
          );
          final tagged = _tagBody(_cipherX3dh, fsBody);
          // wire = frame(1) + envelope header + tagged body
          final wireLen = 1 + TransportEnvelope.headerLen + tagged.length;
          // Fragmentation now carries any frame across a low-MTU link, so we no
          // longer downgrade a large FS frame to SealedBox (which is bigger
          // anyway, and on a ~207B iOS link was itself truncated). Forward
          // secrecy applies to every text to a peer whose prekey we hold.
          body = tagged;
          messages.markForwardSecret(canonicalId, msg.id);
          if (chatId != canonicalId) {
            messages.markForwardSecret(chatId, msg.id);
          }
          DebugLog.instance.log(
              'CRYPTO',
              'sendText: forward-secret (X3DH) to $canonicalId '
                  '(${wireLen}B wire)');
        } catch (e) {
          DebugLog.instance.log('CRYPTO',
              'sendText: FS path failed ($e) — falling back to SealedBox');
          body = null;
        }
      }

      if (body == null) {
        // SealedBox path (no FS). Full signature (0xA1) + length padding.
        final inner = _buildTextInner(utf8Text, replyTarget);
        final signed = await SignedPayload.wrap(
          inner: inner,
          context: ctx,
          signKeyPair: identity.asSignKeyPair(),
          senderEdPub: identity.signPublicKey,
        );
        body =
            _tagBody(_cipherSealedBox, await SealedBox.seal(signed, peerPub));
      }

      final envelope = TransportEnvelope(
        originPubkeyHash: myHash,
        destPubkeyHash: peerHash,
        msgId: msgId,
        ttl: _meshTtl,
        body: body,
      );
      // Pre-record our own msgId in the dedup cache so a reflected copy of
      // this frame coming back over a relay doesn't try to deliver to us.
      _dedup.acceptEnvelope(envelope);

      final outboundFrame = Frame(
        type: FrameType.transport,
        payload: envelope.encode(),
      );

      // Direct-session preferred (single write, lowest latency). Falls back
      // to fan-out across every active link so the mesh can relay when the
      // destination isn't a direct BLE neighbour.
      final transportId = session?.peerId;
      final wireBytes = outboundFrame.encode();
      var deliveredVia = 0;
      MessageRoute? deliveredRoute;
      // Every delivery attempt is wrapped so a transient BLE failure (stale
      // link, peer's Bluetooth turned off, write rejected) leaves
      // deliveredVia == 0 and routes the message into the pending outbox —
      // it must NOT throw to the outer catch and mark the message failed.
      if (transportId != null) {
        final client = _clients[transportId];
        if (client != null && client.isConnected) {
          try {
            await _writeFrameToClient(client, wireBytes);
            deliveredVia = 1;
            deliveredRoute = MessageRoute.bluetooth;
          } catch (e) {
            DebugLog.instance
                .log('MESH', 'direct write failed ($e) — will queue');
          }
        }
        if (deliveredVia == 0) {
          try {
            final ok = await _notifyFrameToPeripheral(wireBytes);
            if (ok) {
              deliveredVia = 1;
              deliveredRoute = MessageRoute.bluetooth;
            }
          } catch (_) {}
        }
        if (deliveredVia == 0) {
          deliveredVia = await _fanoutAllLinks(wireBytes, excludePeerId: null);
          if (deliveredVia > 0) deliveredRoute = MessageRoute.mesh;
        }
      } else {
        deliveredVia = await _fanoutAllLinks(wireBytes, excludePeerId: null);
        if (deliveredVia > 0) deliveredRoute = MessageRoute.mesh;
      }

      // Mesh couldn't carry it → try the internet fallback before queueing.
      // The frame published to a relay is byte-identical to the one BLE would
      // have carried: still SealedBox/X3DH-encrypted and signed, so the relay
      // is a dumb pipe that learns only who talks to whom, and when.
      if (deliveredVia == 0 && await _sendOverNostr(canonicalId, wireBytes)) {
        deliveredVia = 1;
        deliveredRoute = MessageRoute.internet;
      }

      if (deliveredVia > 0) {
        messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
        messages.updateRoute(
            canonicalId, msg.id, deliveredRoute ?? MessageRoute.mesh,
            hops: deliveredRoute == MessageRoute.bluetooth ? 1 : null);
        if (chatId != canonicalId) {
          messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
          messages.updateRoute(
              chatId, msg.id, deliveredRoute ?? MessageRoute.mesh,
              hops: deliveredRoute == MessageRoute.bluetooth ? 1 : null);
        }
      } else {
        messages.updateRoute(canonicalId, msg.id, MessageRoute.queued);
        if (chatId != canonicalId) {
          messages.updateRoute(chatId, msg.id, MessageRoute.queued);
        }
        // Recipient unreachable right now → opportunistic store-and-forward:
        // hold the encrypted frame and hand it over the moment they connect
        // (handled by _flushStoreForwardFor on the next handshake). The
        // message stays "sending" until then; _outbox flips it to delivered
        // once it's actually handed off.
        _store.store(
          destHash: peerHash,
          frameBytes: wireBytes,
          origin: myHash,
          msgId: msgId,
        );
        _outbox[TransportEnvelope.hashHex(msgId)] = _OutboxRef(
          canonicalId: canonicalId,
          chatId: chatId,
          messageId: msg.id,
        );
        _scheduleRelayPersist();
        DebugLog.instance.log(
            'MESH',
            'text undeliverable — queued for store-and-forward to '
                '$canonicalId (held ${_store.size})');
        // Leave status as sending (pending), not failed.
      }
    } catch (e, st) {
      DebugLog.instance.log('NOISE', 'sendText FAILED: $e');
      debugPrint('sendText failed: $e\n$st');
      messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.failed);
      }
    }
    return msg;
  }

  /// M5.4: send an image as a series of SealedBox-encrypted chunks. Each
  /// chunk is a separate envelope so it routes the same way as a text
  /// message and so partial transfers don't block other traffic. Chunks
  /// are emitted strictly in order on the same link to keep MTU stress
  /// from re-ordering them on lossy stacks. The caller gets back the
  /// pending Message immediately; status flips to delivered once the last
  /// chunk's BLE write resolves, or failed on the first error.
  /// Largest file we will put on the mesh.
  ///
  /// This one *is* the protocol limit, exactly. A BLE media chunk is
  /// [kBleMediaChunkData] = 4096 bytes on any link we can negotiate (the
  /// fragmenter, not the MTU, decides it — see [bleMediaChunkData]), and
  /// [FileChunk.maxChunks] is 8192. 8192 × 4096 is 32 MiB and not a byte more:
  /// past it `sendFile` throws "too many chunks" rather than sending anything.
  ///
  /// Worth knowing before reaching for a bigger number: at the ~14 KB/s a real
  /// Bluetooth link sustains, 32 MiB is already about forty minutes on the
  /// radio. Raising the chunk cap would buy hours, not megabytes.
  static const int maxFileBytesMesh = 32 * 1024 * 1024;

  /// And over the internet fallback, where every chunk is one relay event.
  ///
  /// The number that matters here is the publish count, not the byte count:
  /// public relays rate-limit, and that limit lands on ordinary messages too.
  /// At 32 KiB a chunk (see [FileChunk.maxDataBytes] for why that is the
  /// ceiling) 64 MiB is 2048 publishes per relay — minutes of transfer you can
  /// watch and pause, and comfortably inside [FileChunk.maxChunks].
  ///
  /// This is where the ceiling stops being arithmetic and starts being other
  /// people's servers. A relay is not a file host: it prunes, it caps event
  /// size, and it answers a burst by throttling you. 2048 events is a lot to
  /// ask of one and roughly the most that is polite; a gigabyte would be
  /// ~33,000, which no public relay will carry however patient the sender is.
  /// Delivery rides out a refusal now ([_deliverMediaFrameRetrying]) instead of
  /// failing the whole file on the first one, which is what makes a transfer
  /// this size land at all.
  static const int maxFileBytesRelay = 64 * 1024 * 1024;

  /// Send [file] as-is, keeping its name.
  ///
  /// Unlike [sendImage] the bytes are never all in memory: the hash is
  /// computed by streaming the file, and each chunk is read from disk as it
  /// goes out. A twenty-five megabyte attachment would otherwise be held twice
  /// over — once as the source buffer and once inside the frames.
  /// [reuseMediaId] and [appendLocally] are how a re-send differs from a send:
  /// the peer asked for a file they already have a bubble for, so it goes back
  /// under the id that bubble is keyed on, and nothing new is added to the
  /// conversation at this end. See [handleMediaRequest].
  Future<Message> sendFile(
    String chatId, {
    required File file,
    required String fileName,
    String mime = 'application/octet-stream',
    Uint8List? reuseMediaId,
    bool appendLocally = true,
  }) async {
    final manager = _ref.read(chatSessionManagerProvider.notifier);
    ChatSession? session = manager.sessionFor(chatId);
    session ??= _findSessionByPubkeyHex(chatId);

    Uint8List? peerPub;
    String? canonicalId;
    if (session != null && session.isEstablished) {
      peerPub = session.remoteStaticPublicKey;
      canonicalId = session.remotePubkeyHex ?? chatId;
    } else {
      final known = _ref.read(knownPeersControllerProvider)[chatId];
      if (known != null) {
        try {
          peerPub = _hexDecodeBytes(known.pubkeyHex);
          canonicalId = known.pubkeyHex;
        } catch (e) {
          DebugLog.instance
              .log('FILE', 'sendFile: malformed pubkey hex for $chatId: $e');
        }
      }
    }
    if (peerPub == null || canonicalId == null) {
      throw StateError('cannot send file: no recipient pubkey for $chatId');
    }

    final size = await file.length();
    final relayOnly = !_hasAnyLink && _relayClient?.isConnected == true;
    final cap = relayOnly ? maxFileBytesRelay : maxFileBytesMesh;
    if (size > cap) {
      throw FileTooLarge(size: size, cap: cap, relayOnly: relayOnly);
    }
    if (size == 0) throw StateError('cannot send an empty file');

    final safe = safeFileName(fileName);
    final fileId = reuseMediaId ?? ImageChunk.newImageId();

    // Kept in the app's own storage so the bubble still resolves after the
    // picker's temporary copy is collected. A re-send is already reading that
    // copy, so it stays where it is rather than being duplicated beside itself.
    final File stored;
    if (reuseMediaId != null) {
      stored = file;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final outbox =
          Directory('${dir.path}${Platform.pathSeparator}cubechat-outbox');
      if (!await outbox.exists()) await outbox.create(recursive: true);
      stored = File('${outbox.path}${Platform.pathSeparator}'
          '${_hexOf(fileId).substring(0, 8)}-$safe');
      await file.copy(stored.path);
    }

    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: canonicalId,
      text: mime,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      kind: MessageKind.file,
      filePath: stored.path,
      fileName: safe,
      fileBytes: size,
      wireId: TransportEnvelope.hashHex(fileId),
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    if (appendLocally) {
      messages.append(canonicalId, msg);
      if (chatId != canonicalId) messages.append(chatId, msg);
    }

    final transferId = _hexOf(fileId);
    final transfers = _ref.read(fileTransferControllerProvider.notifier);
    transfers.register(
      FileTransferTask(
        id: transferId,
        chatId: canonicalId,
        fileName: safe,
        messageId: msg.id,
        filePath: stored.path,
        mime: mime,
        bytesTotal: size,
        completedUnits: 0,
        totalUnits: 0,
        direction: FileTransferDirection.outgoing,
        status: FileTransferStatus.queued,
        createdAt: msg.sentAt,
        updatedAt: msg.sentAt,
      ),
    );
    if (!_hasMediaRoute(canonicalId)) {
      return msg;
    }

    try {
      final tid = session?.peerId;
      final direct = tid != null ? _clients[tid] : null;
      final chunkData = _mediaChunkData(direct,
          relayOnly: relayOnly, ceiling: FileChunk.maxDataBytes);
      final total = (size + chunkData - 1) ~/ chunkData;
      if (total < 1 || total > FileChunk.maxChunks) {
        throw StateError(
          'file too large: $total chunks > ${FileChunk.maxChunks} cap',
        );
      }
      transfers.setProgress(transferId, 0, total);

      // Streamed, so the digest costs one buffer rather than the whole file.
      final sink = Sha256().newHashSink();
      await for (final part in stored.openRead()) {
        sink.add(part);
      }
      sink.close();
      final digest = Uint8List.fromList((await sink.hash()).bytes);

      final myHash = await _myPubkeyHash();
      final peerHash = await _peerPubkeyHash(peerPub);
      final fs = await _deriveMediaFsSetup(canonicalId, peerPub);
      await _sendSignedManifest(
        mediaId: fileId,
        kind: MediaKind.file,
        total: total,
        mime: mime,
        name: safe,
        sha256Digest: digest,
        myHash: myHash,
        peerHash: peerHash,
        peerPub: peerPub,
        session: session,
        canonicalId: canonicalId,
        relayOnly: relayOnly,
        senderIdentityPub: fs?.identityPub,
        senderEphemeralPub: fs?.ephemeralPub,
      );

      final handle = await stored.open();
      // Grows the moment the far end pushes back, and never shrinks again for
      // this file. See [_deliverMediaFrameRetrying].
      var gap = Duration.zero;
      try {
        for (var i = 0; i < total; i++) {
          if (!await transfers.waitUntilRunnable(transferId)) {
            messages.updateStatus(
              canonicalId,
              msg.id,
              MessageStatus.failed,
            );
            if (chatId != canonicalId) {
              messages.updateStatus(chatId, msg.id, MessageStatus.failed);
            }
            return msg;
          }
          final want = (i == total - 1) ? size - i * chunkData : chunkData;
          final data = await handle.read(want);
          final chunk = FileChunk(
            fileId: fileId,
            seq: i,
            total: total,
            data: data,
          );
          final inner =
              packInnerPayload(InnerPayloadType.fileChunk, chunk.encode());
          final body = fs != null
              ? _tagBody(
                  _cipherX3dhMedia,
                  await MediaFsCipher.seal(
                      key: fs.key, mediaId: fileId, plaintext: inner))
              : _tagBody(
                  _cipherSealedBox, await SealedBox.seal(inner, peerPub));
          final env = TransportEnvelope(
            originPubkeyHash: myHash,
            destPubkeyHash: peerHash,
            msgId: TransportEnvelope.newMsgId(initialTtl: _meshTtl),
            ttl: _meshTtl,
            body: body,
          );
          _dedup.acceptEnvelope(env);
          final delivery = await _deliverMediaFrameRetrying(
            frameBytes: Frame(type: FrameType.transport, payload: env.encode())
                .encode(),
            session: session,
            canonicalId: canonicalId,
            relayOnly: relayOnly,
            gap: gap,
          );
          gap = delivery.gap;
          if (!delivery.sent) {
            throw const MediaRouteUnavailable();
          }
          transfers.setProgress(transferId, i + 1, total);
          if (i + 1 < total) {
            // Over BLE, a fixed gap: some Android stacks drop notifies when the
            // sender outruns the receiver's read loop. Over the relay there is
            // already a round trip per chunk, so the only gap is whatever the
            // relay has asked for by refusing something.
            final pause =
                relayOnly ? gap : const Duration(milliseconds: 15) + gap;
            if (pause > Duration.zero) await Future<void>.delayed(pause);
          }
        }
      } finally {
        await handle.close();
      }

      messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
      }
      transfers.setStatus(transferId, FileTransferStatus.completed);
    } catch (e, st) {
      // Named and measured, because "sendFile failed" on its own never
      // identified *which* file — and the reports that matter are always "this
      // one goes, those don't".
      DebugLog.instance
          .log('FILE', 'sendFile failed for "$safe" ($size B, $mime): $e');
      debugPrint('$st');
      messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.failed);
      }
      transfers.setStatus(
        transferId,
        FileTransferStatus.failed,
        error: e.toString(),
      );
      rethrow;
    }
    return msg;
  }

  Future<void> retryFileTransfer(String transferId) async {
    final transfers = _ref.read(fileTransferControllerProvider.notifier);
    final task = _ref.read(fileTransferControllerProvider)[transferId];
    if (task == null) return;
    // Retrying a transfer *into* this phone is asking for it again: the bytes
    // are the sender's, and their outbox is the only place a second copy
    // exists. The transfer centre has always offered the button here; it used
    // to return at this line and do nothing at all.
    if (task.direction == FileTransferDirection.incoming) {
      if (await requestMediaAgain(task.chatId, transferId)) {
        transfers.setStatus(transferId, FileTransferStatus.queued);
      }
      return;
    }
    if (!_hasMediaRoute(task.chatId)) return;
    final file = File(task.filePath);
    if (!await file.exists()) {
      transfers.setStatus(
        transferId,
        FileTransferStatus.failed,
        error: 'source file is missing',
      );
      return;
    }
    await transfers.remove(transferId);
    final messages = _ref.read(messagesControllerProvider.notifier);
    if (task.messageId case final messageId?) {
      messages.deleteLocal(task.chatId, messageId);
    }
    await sendFile(
      task.chatId,
      file: file,
      fileName: task.fileName,
      mime: task.mime,
    );
  }

  Future<Message> sendImage(
    String chatId, {
    required Uint8List bytes,
    required String mime,
    String? cachedPath,
    String? caption,
    bool viewOnce = false,
  }) async {
    final manager = _ref.read(chatSessionManagerProvider.notifier);
    ChatSession? session = manager.sessionFor(chatId);
    session ??= _findSessionByPubkeyHex(chatId);

    Uint8List? peerPub;
    String? canonicalId;
    if (session != null && session.isEstablished) {
      peerPub = session.remoteStaticPublicKey;
      canonicalId = session.remotePubkeyHex ?? chatId;
    } else {
      final known = _ref.read(knownPeersControllerProvider)[chatId];
      if (known != null) {
        try {
          peerPub = _hexDecodeBytes(known.pubkeyHex);
          canonicalId = known.pubkeyHex;
        } catch (e) {
          DebugLog.instance
              .log('IMG', 'sendImage: malformed pubkey hex for $chatId: $e');
        }
      }
    }
    if (peerPub == null || canonicalId == null) {
      throw StateError('cannot send image: no recipient pubkey for $chatId');
    }
    _requireMediaRoute(canonicalId);

    // Minted before the bubble so it can carry the media id as its wireId — the
    // same handle the receiver files this photo under. That symmetry is what
    // lets a read receipt for a photo find its way back to this message (and,
    // with it, the read time in the long-press details).
    final imageId = ImageChunk.newImageId();
    // The bubble shows the caption when there is one; the mime is the fallback
    // label the preview line already knows to hide.
    final caption0 = (caption?.trim().isEmpty ?? true) ? null : caption!.trim();
    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: canonicalId,
      text: caption0 ?? mime,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      kind: MessageKind.image,
      imagePath: cachedPath,
      imageMime: mime,
      wireId: TransportEnvelope.hashHex(imageId),
      viewOnce: viewOnce,
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);
    if (chatId != canonicalId) {
      messages.append(chatId, msg);
    }

    try {
      // Size chunks to the link's real MTU so a full chunk-frame fits one BLE
      // write. A fixed 140 overflowed low-MTU iOS links (the frame was
      // truncated, the AEAD open then failed). Fragmentation is the safety net,
      // but a chunk that fits avoids per-fragment overhead and the notify-queue
      // churn that aborted transfers around chunk 300 on iOS peripheral links.
      final imgTid = session?.peerId;
      final imgDirect = imgTid != null ? _clients[imgTid] : null;
      // One decision for the whole transfer: with no BLE link at all it goes
      // over the relay, which also sets the chunk size.
      //
      // The relay has to actually be up for that to mean anything — the same
      // condition [sendFile] uses. Without the second half, a phone with no
      // link *and* no internet still committed the transfer to relay-only,
      // which makes [_deliverMediaFrame] skip every Bluetooth path outright:
      // a link coming back mid-send could not be used, and the failure
      // surfaced from inside the manifest send rather than from the route
      // check at the top. A field log caught exactly that — the check passed
      // while a central was connected, the link dropped during the async
      // setup below, and the send went relay-only into a dead relay.
      final relayOnly = !_hasAnyLink && _relayClient?.isConnected == true;
      final chunkData = _mediaChunkData(imgDirect,
          relayOnly: relayOnly, ceiling: ImageChunk.maxDataBytes);
      final total = (bytes.length + chunkData - 1) ~/ chunkData;
      if (total < 1 || total > ImageChunk.maxChunks) {
        throw StateError(
          'image too large: $total chunks > ${ImageChunk.maxChunks} cap',
        );
      }
      final myHash = await _myPubkeyHash();
      final peerHash = await _peerPubkeyHash(peerPub);
      // Seal the chunks forward-secret when we hold the recipient's prekey.
      final fs = await _deriveMediaFsSetup(canonicalId, peerPub);
      await _sendSignedManifest(
        mediaId: imageId,
        kind: MediaKind.image,
        total: total,
        mime: mime,
        caption: caption0,
        viewOnce: viewOnce,
        bytes: bytes,
        myHash: myHash,
        peerHash: peerHash,
        peerPub: peerPub,
        session: session,
        canonicalId: canonicalId,
        relayOnly: relayOnly,
        senderIdentityPub: fs?.identityPub,
        senderEphemeralPub: fs?.ephemeralPub,
      );
      if (fs != null) {
        DebugLog.instance.log(
            'CRYPTO', 'sendImage: forward-secret (X3DH) media to $canonicalId');
      }
      var imgGap = Duration.zero;
      for (var i = 0; i < total; i++) {
        final start = i * chunkData;
        final end = (start + chunkData).clamp(0, bytes.length);
        final chunk = ImageChunk(
          imageId: imageId,
          seq: i,
          total: total,
          mime: mime,
          data: Uint8List.fromList(bytes.sublist(start, end)),
        );
        final inner =
            packInnerPayload(InnerPayloadType.imageChunk, chunk.encode());
        final body = fs != null
            ? _tagBody(
                _cipherX3dhMedia,
                await MediaFsCipher.seal(
                    key: fs.key, mediaId: imageId, plaintext: inner))
            : _tagBody(_cipherSealedBox, await SealedBox.seal(inner, peerPub));
        final env = TransportEnvelope(
          originPubkeyHash: myHash,
          destPubkeyHash: peerHash,
          msgId: TransportEnvelope.newMsgId(initialTtl: _meshTtl),
          ttl: _meshTtl,
          body: body,
        );
        _dedup.acceptEnvelope(env);
        final frameBytes = Frame(
          type: FrameType.transport,
          payload: env.encode(),
        ).encode();

        final delivery = await _deliverMediaFrameRetrying(
          frameBytes: frameBytes,
          session: session,
          canonicalId: canonicalId,
          relayOnly: relayOnly,
          gap: imgGap,
        );
        imgGap = delivery.gap;
        if (!delivery.sent) {
          throw const MediaRouteUnavailable();
        }
        // Tiny pacing gap. Some Android BLE stacks lose notify packets when
        // a fast sender outpaces the receiver's read loop. 15ms is below
        // human perception in aggregate (~5s for a 300-chunk image) and
        // well above the worst-case per-chunk turn-around on tested
        // hardware. Over the relay the only gap is one the relay asked for.
        if (i + 1 < total) {
          final pause =
              relayOnly ? imgGap : const Duration(milliseconds: 15) + imgGap;
          if (pause > Duration.zero) await Future<void>.delayed(pause);
        }
      }
      messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
      }
    } catch (e, st) {
      debugPrint('sendImage failed: $e\n$st');
      messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.failed);
      }
      // Surface it: the caller shows a snackbar. Silently swallowing left the
      // user with a broken bubble and no idea the link had dropped.
      rethrow;
    }
    return msg;
  }

  /// Send a voice message as a series of SealedBox-encrypted audio chunks.
  /// Same chunking + pacing as sendImage; the receiver's AudioReassembler
  /// joins them back and emits a Message.kind=audio with playback metadata.
  Future<Message> sendAudio(
    String chatId, {
    required Uint8List bytes,
    required String mime,
    required int durationMs,
    String? cachedPath,
  }) async {
    final manager = _ref.read(chatSessionManagerProvider.notifier);
    ChatSession? session = manager.sessionFor(chatId);
    session ??= _findSessionByPubkeyHex(chatId);

    Uint8List? peerPub;
    String? canonicalId;
    if (session != null && session.isEstablished) {
      peerPub = session.remoteStaticPublicKey;
      canonicalId = session.remotePubkeyHex ?? chatId;
    } else {
      final known = _ref.read(knownPeersControllerProvider)[chatId];
      if (known != null) {
        try {
          peerPub = _hexDecodeBytes(known.pubkeyHex);
          canonicalId = known.pubkeyHex;
        } catch (e) {
          DebugLog.instance
              .log('VOICE', 'sendAudio: malformed pubkey hex for $chatId: $e');
        }
      }
    }
    if (peerPub == null || canonicalId == null) {
      throw StateError('cannot send audio: no recipient pubkey for $chatId');
    }
    _requireMediaRoute(canonicalId);

    // Media id up front, so the bubble's wireId matches what the receiver files
    // this voice note under (see sendImage).
    final audioId = AudioChunk.newAudioId();
    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: canonicalId,
      text: mime,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      kind: MessageKind.audio,
      audioPath: cachedPath,
      audioMime: mime,
      audioDurationMs: durationMs,
      wireId: TransportEnvelope.hashHex(audioId),
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);
    if (chatId != canonicalId) {
      messages.append(chatId, msg);
    }

    try {
      // Size chunks to the link's real MTU (see sendImage for the why).
      final audTid = session?.peerId;
      final audDirect = audTid != null ? _clients[audTid] : null;
      final relayOnly = !_hasAnyLink;
      final chunkData = _mediaChunkData(audDirect,
          relayOnly: relayOnly, ceiling: AudioChunk.maxDataBytes);
      final total = (bytes.length + chunkData - 1) ~/ chunkData;
      if (total < 1 || total > AudioChunk.maxChunks) {
        throw StateError(
          'audio too large: $total chunks > ${AudioChunk.maxChunks} cap',
        );
      }
      final myHash = await _myPubkeyHash();
      final peerHash = await _peerPubkeyHash(peerPub);
      final fs = await _deriveMediaFsSetup(canonicalId, peerPub);
      await _sendSignedManifest(
        mediaId: audioId,
        kind: MediaKind.audio,
        total: total,
        mime: mime,
        durationMs: durationMs,
        bytes: bytes,
        myHash: myHash,
        peerHash: peerHash,
        peerPub: peerPub,
        session: session,
        canonicalId: canonicalId,
        relayOnly: relayOnly,
        senderIdentityPub: fs?.identityPub,
        senderEphemeralPub: fs?.ephemeralPub,
      );
      if (fs != null) {
        DebugLog.instance.log(
            'CRYPTO', 'sendAudio: forward-secret (X3DH) media to $canonicalId');
      }
      for (var i = 0; i < total; i++) {
        final start = i * chunkData;
        final end = (start + chunkData).clamp(0, bytes.length);
        final chunk = AudioChunk(
          audioId: audioId,
          seq: i,
          total: total,
          durationMs: durationMs,
          mime: mime,
          data: Uint8List.fromList(bytes.sublist(start, end)),
        );
        final inner =
            packInnerPayload(InnerPayloadType.audioChunk, chunk.encode());
        // Unsigned: audio chunks pay no per-chunk signature cost (would
        // overflow MTU). Integrity rides on the AEAD (SealedBox or, when the
        // recipient's prekey is known, forward-secret MediaFsCipher); sender
        // identity rides on the signed manifest + announcement chain.
        final body = fs != null
            ? _tagBody(
                _cipherX3dhMedia,
                await MediaFsCipher.seal(
                    key: fs.key, mediaId: audioId, plaintext: inner))
            : _tagBody(_cipherSealedBox, await SealedBox.seal(inner, peerPub));
        final env = TransportEnvelope(
          originPubkeyHash: myHash,
          destPubkeyHash: peerHash,
          msgId: TransportEnvelope.newMsgId(initialTtl: _meshTtl),
          ttl: _meshTtl,
          body: body,
        );
        _dedup.acceptEnvelope(env);
        final frameBytes = Frame(
          type: FrameType.transport,
          payload: env.encode(),
        ).encode();

        final sent = await _deliverMediaFrame(
          frameBytes: frameBytes,
          session: session,
          canonicalId: canonicalId,
          relayOnly: relayOnly,
        );
        if (!sent) {
          throw const MediaRouteUnavailable();
        }
        // BLE notify pacing; see sendImage. Not needed over the relay.
        if (i + 1 < total && !relayOnly) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
      }
      messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
      }
    } catch (e, st) {
      debugPrint('sendAudio failed: $e\n$st');
      messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.failed);
      }
      // Surface it (see sendImage) so the caller can tell the user why.
      rethrow;
    }
    return msg;
  }

  // -------------------- read receipts / reactions / channels --------------

  /// Acknowledge every not-yet-acked inbound message in [canonicalId] as
  /// *read*. Called when the user opens / views a chat.
  ///
  /// Works for a `#channel` as well as a pubkey-hex peer. The difference is
  /// only in who hears it: a 1:1 receipt is sealed to the one person who sent
  /// the message, while a channel receipt is broadcast under the channel key
  /// like any other channel payload, because a channel has no member roster to
  /// address and the sender is not knowable from the transport. Every member
  /// therefore sees every other member's acknowledgement — which is what makes
  /// "read by" possible there at all.
  ///
  /// Best-effort: a send failure rolls the ack back so the next view retries.
  Future<void> sendReadReceipts(String canonicalId) async {
    // Opted out of read receipts: say nothing. The messages are still marked
    // read locally — this only withholds telling anyone else about it.
    if (!_ref.read(privacySettingsProvider).shareReadReceipts) return;
    final msgs = _ref.read(messagesControllerProvider)[canonicalId];
    if (msgs == null || msgs.isEmpty) return;

    final isChannel = canonicalId.startsWith('#');
    final channel = isChannel
        ? _ref.read(channelControllerProvider.notifier).byName(canonicalId)
        : null;
    if (isChannel && channel == null) return; // left it, or never joined

    final fresh = <Uint8List>[];
    for (final m in msgs) {
      if (m.isMine) continue;
      final w = m.wireId;
      if (w == null || _sentReadAcks.contains(w)) continue;
      try {
        fresh.add(_hexDecodeBytes(w));
      } catch (_) {/* skip malformed wireId */}
    }
    if (fresh.isEmpty) return;

    final peerPub = isChannel ? null : _resolvePeerPub(canonicalId);
    if (!isChannel && peerPub == null) return;

    for (var i = 0; i < fresh.length; i += ReadReceipt.maxIdsPerFrame) {
      final end = (i + ReadReceipt.maxIdsPerFrame).clamp(0, fresh.length);
      final slice = fresh.sublist(i, end);
      final receipt = ReadReceipt(status: ReceiptStatus.read, msgIds: slice);
      try {
        // Remembered as acknowledged only once it actually went somewhere.
        //
        // These used to be marked in the loop that collected them, before any
        // of them had been sent, and undone only if the send *threw*. But
        // neither path throws when there is simply no route: _sendControlToPeer
        // and _broadcastChannelFrame both return a fan-out count, and zero is
        // an ordinary return. So a receipt composed with Bluetooth down and the
        // relay unreachable — which is most of the time on a phone with no
        // internet — was recorded as delivered, never retried for the life of
        // the process, and the sender's tick stayed on one forever.
        final int fanout;
        if (channel != null) {
          final frame = await _buildChannelFrame(
            channel,
            InnerPayloadType.receipt,
            receipt.encode(),
            TransportEnvelope.newMsgId(initialTtl: _meshTtl),
          );
          fanout = await _broadcastChannelFrame(frame);
        } else {
          fanout = await _sendControlToPeer(
            canonicalId: canonicalId,
            peerPub: peerPub!,
            type: InnerPayloadType.receipt,
            innerBody: receipt.encode(),
          );
        }
        if (fanout > 0) {
          for (final id in slice) {
            _sentReadAcks.add(TransportEnvelope.hashHex(id));
          }
        } else {
          DebugLog.instance.log(
              'RECEIPT', 'no route for ${slice.length} read ack(s) — will retry');
        }
      } catch (e) {
        DebugLog.instance.log('RECEIPT', 'read-receipt send failed: $e');
      }
    }
  }

  /// Add or toggle-off an emoji [emoji] reaction on the message identified by
  /// [targetWireId] in [chatId] (a pubkey-hex peer chat or a `#channel`).
  /// Applies locally first (optimistic) then puts it on the wire.
  Future<void> sendReaction(
    String chatId,
    String targetWireId,
    String emoji, {
    required bool add,
  }) async {
    final Uint8List target;
    try {
      target = _hexDecodeBytes(targetWireId);
    } catch (_) {
      return;
    }
    if (target.length != Reaction.idLen) return;

    // Optimistic local echo.
    _ref.read(messagesControllerProvider.notifier).applyReaction(
          chatId,
          targetWireId: targetWireId,
          emoji: emoji,
          reactorId: 'me',
          add: add,
        );

    final reaction = Reaction(
      op: add ? ReactionOp.add : ReactionOp.remove,
      emoji: emoji,
      targetMsgId: target,
    );
    final body = reaction.encode();
    try {
      if (chatId.startsWith('#')) {
        final channel =
            _ref.read(channelControllerProvider.notifier).byName(chatId);
        if (channel == null) return;
        final msgId = TransportEnvelope.newMsgId(initialTtl: _meshTtl);
        final frame = await _buildChannelFrame(
            channel, InnerPayloadType.reaction, body, msgId);
        await _broadcastChannelFrame(frame);
      } else {
        final peerPub = _resolvePeerPub(chatId);
        if (peerPub == null) return;
        await _sendControlToPeer(
          canonicalId: chatId,
          peerPub: peerPub,
          type: InnerPayloadType.reaction,
          innerBody: body,
        );
      }
    } catch (e) {
      DebugLog.instance.log('REACT', 'reaction send failed: $e');
    }
  }

  /// Shortest gap between two "still typing" frames.
  ///
  /// The composer calls [announceTyping] on every keystroke, so without this a
  /// sentence would be forty frames. Comfortably inside [TypingController.ttl]
  /// so the indicator never lapses mid-word.
  static const Duration typingMinInterval = Duration(seconds: 3);

  final Map<String, DateTime> _lastTypingSentAt = {};

  /// Tell one peer we are writing to them, or have stopped.
  ///
  /// Best-effort and deliberately quiet about failure: a typing notice that
  /// does not arrive is not worth a log line, let alone a retry — by the time
  /// anything could be retried the fact has changed.
  ///
  /// Gated on [PrivacySettings.shareLastSeen], the same switch presence uses,
  /// rather than a second one. It is the same question — how much of my
  /// liveness do I leak — and the same symmetric bargain: turn it off and you
  /// stop seeing other people's typing too (see [_ingestTyping]).
  Future<void> announceTyping(String canonicalId, {bool typing = true}) async {
    if (_disposed) return;
    if (!_ref.read(privacySettingsProvider).shareLastSeen) return;
    if (!AppLifecycle.instance.isForeground) return;
    if (canonicalId.startsWith('#')) return; // 1:1 only

    if (typing) {
      final last = _lastTypingSentAt[canonicalId];
      if (last != null &&
          DateTime.now().difference(last) < typingMinInterval) {
        return;
      }
      _lastTypingSentAt[canonicalId] = DateTime.now();
    } else {
      // A stop is never throttled — it is the frame that ends the indicator
      // early, and it only happens once per burst of typing anyway.
      _lastTypingSentAt.remove(canonicalId);
    }

    final peerPub = _resolvePeerPub(canonicalId);
    if (peerPub == null) return;
    try {
      await _sendControlToPeer(
        canonicalId: canonicalId,
        peerPub: peerPub,
        type: InnerPayloadType.typing,
        innerBody: Uint8List.fromList([typing ? 0x01 : 0x00]),
      );
    } catch (_) {
      // See above: a lost typing notice is not an error worth reporting.
    }
  }

  /// A peer is writing to us — or has stopped.
  void _ingestTyping({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    if (body.isEmpty) return;
    final canonicalId = senderPub != null ? _hexOf(senderPub) : peerId;
    final controller = _ref.read(typingControllerProvider.notifier);
    if (body[0] == 0x01) {
      controller.record(canonicalId);
    } else {
      controller.clear(canonicalId);
    }
  }

  /// Ask the peer to delete this conversation on their side too.
  ///
  /// 1:1 only, and best-effort by nature: it is a request their app honours,
  /// not something this one can enforce. Returns whether it reached anything,
  /// so the caller can say if it went nowhere.
  Future<bool> sendConversationClear(String canonicalId) async {
    if (canonicalId.startsWith('#')) return false;
    final peerPub = _resolvePeerPub(canonicalId);
    if (peerPub == null) return false;
    try {
      final fanout = await _sendControlToPeer(
        canonicalId: canonicalId,
        peerPub: peerPub,
        type: InnerPayloadType.conversationClear,
        innerBody: Uint8List(0),
      );
      DebugLog.instance
          .log('CHAT', 'asked $canonicalId to clear the conversation ($fanout)');
      return fanout > 0;
    } catch (e) {
      DebugLog.instance.log('CHAT', 'conversation clear failed: $e');
      return false;
    }
  }

  /// The peer deleted this conversation and asked us to do the same.
  ///
  /// Only ever clears the one chat it arrived on, and only from a sender the
  /// signature already identified — there is no id in the body to point
  /// somewhere else with.
  Future<void> _ingestConversationClear({
    required String peerId,
    required Uint8List? senderPub,
  }) async {
    final messages = _ref.read(messagesControllerProvider.notifier);
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    await messages.clearForChat(canonical);
    if (canonical != peerId) await messages.clearForChat(peerId);
    DebugLog.instance.log('CHAT', '$canonical cleared the conversation here');
  }

  /// Burn a view-once photo here, and tell the other side to burn theirs.
  ///
  /// Called from both directions and idempotent in both: the recipient calls
  /// it when they close the viewer, the sender when the recipient's ack lands.
  /// [notifyPeer] is what separates the two — the ack must not bounce back and
  /// forth forever.
  ///
  /// The local burn happens whether or not the message reaches the peer. A
  /// photo that stays on this phone because the link was down is the one
  /// failure this feature cannot afford; the peer's own copy is theirs to
  /// remove when they hear, and their app will do it on the next delivery of
  /// this frame or not at all.
  Future<void> consumeViewOnce(
    String chatId,
    String wireIdHex, {
    bool notifyPeer = true,
  }) async {
    final messages = _ref.read(messagesControllerProvider.notifier);
    final burned = await messages.consumeViewOnce(chatId, wireIdHex);
    // Mirror into any transport-id bucket the same conversation is open under.
    for (final id in _ref.read(messagesControllerProvider).keys) {
      if (id != chatId) await messages.consumeViewOnce(id, wireIdHex);
    }
    if (burned == null || !notifyPeer) return;

    final Uint8List mediaId;
    try {
      mediaId = _hexDecodeBytes(wireIdHex);
    } catch (_) {
      return;
    }
    if (mediaId.length != ImageChunk.idLen) return;
    final peerPub = _resolvePeerPub(chatId);
    if (peerPub == null) return;
    try {
      await _sendControlToPeer(
        canonicalId: chatId,
        peerPub: peerPub,
        type: InnerPayloadType.viewOnceConsumed,
        innerBody: mediaId,
      );
      DebugLog.instance
          .log('VIEWONCE', 'told $chatId their copy of $wireIdHex is spent');
    } catch (e) {
      DebugLog.instance.log('VIEWONCE', 'consume ack to $chatId failed: $e');
    }
  }

  /// The other side opened the view-once photo we sent — drop our copy too.
  Future<void> _ingestViewOnceConsumed({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) async {
    if (body.length != ImageChunk.idLen) return;
    final wireId = TransportEnvelope.hashHex(body);
    // Keyed on the canonical id when we can name the sender: that is the
    // bucket our own outgoing copy was filed under.
    final chatId = senderPub != null ? _hexOf(senderPub) : peerId;
    await consumeViewOnce(chatId, wireId, notifyPeer: false);
    DebugLog.instance.log('VIEWONCE', 'our copy of $wireId burned by $chatId');
  }

  /// Ask the peer to send a file again, by the media id its bubble is keyed on.
  ///
  /// A received file lives on this phone and nowhere else — no server holds a
  /// copy — so clearing it in the transfer centre left the bubble pointing at
  /// a path that no longer existed, unopenable for good. The one party who
  /// still has the bytes is whoever sent them, and their own copy is sitting in
  /// their outbox. 1:1 only: a room has no single person to ask.
  Future<bool> requestMediaAgain(String chatId, String wireIdHex) async {
    if (chatId.startsWith('#')) return false;
    final Uint8List mediaId;
    try {
      mediaId = _hexDecodeBytes(wireIdHex);
    } catch (_) {
      return false;
    }
    if (mediaId.length != ImageChunk.idLen) return false;
    final peerPub = _resolvePeerPub(chatId);
    if (peerPub == null) return false;
    try {
      await _sendControlToPeer(
        canonicalId: chatId,
        peerPub: peerPub,
        type: InnerPayloadType.mediaRequest,
        innerBody: mediaId,
      );
      DebugLog.instance.log('FILE', 'asked $chatId for media $wireIdHex again');
      return true;
    } catch (e) {
      DebugLog.instance.log('FILE', 'media re-request failed: $e');
      return false;
    }
  }

  /// Answer a [InnerPayloadType.mediaRequest]: find our own copy and send it
  /// back under the same media id.
  ///
  /// Only ever our own outgoing file, and only one we still hold — this is a
  /// peer naming an id and asking for bytes, so it must not be able to name
  /// anything else. The id is one we minted and they already received, and the
  /// answer is the same file it always was, hashed and signed again on the way
  /// out.
  Future<void> _handleMediaRequest({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) async {
    if (body.length != ImageChunk.idLen) return;
    final wireId = TransportEnvelope.hashHex(body);
    final chatId = senderPub != null ? _hexOf(senderPub) : peerId;
    final messages = _ref.read(messagesControllerProvider)[chatId] ?? const [];
    Message? mine;
    for (final m in messages) {
      if (m.wireId == wireId && m.isMine && m.kind == MessageKind.file) {
        mine = m;
        break;
      }
    }
    final path = mine?.filePath;
    if (mine == null || path == null || !await File(path).exists()) {
      DebugLog.instance
          .log('FILE', 'cannot answer media request $wireId: not held here');
      return;
    }
    try {
      await sendFile(
        chatId,
        file: File(path),
        fileName: mine.fileName ?? 'file',
        mime: mine.text,
        reuseMediaId: body,
        appendLocally: false,
      );
      DebugLog.instance.log('FILE', 're-sent $wireId to $chatId on request');
    } catch (e) {
      DebugLog.instance.log('FILE', 're-send of $wireId failed: $e');
    }
  }

  /// Rewrite one of our own already-sent text messages, in a peer chat or a
  /// channel, and push the new text to everyone who has the old one.
  ///
  /// No-ops when [targetWireId] doesn't name a text message of ours — the local
  /// store is the authority on that, so nothing goes on the wire either.
  Future<void> sendEdit(
    String chatId,
    String targetWireId,
    String newText,
  ) async {
    final Uint8List target;
    try {
      target = _hexDecodeBytes(targetWireId);
    } catch (_) {
      return;
    }
    if (target.length != MessageEdit.idLen) return;

    final messages = _ref.read(messagesControllerProvider.notifier);
    if (!messages.editMine(chatId, targetWireId, newText)) return;

    final body = MessageEdit(targetMsgId: target, text: newText).encode();
    try {
      if (chatId.startsWith('#')) {
        final channel =
            _ref.read(channelControllerProvider.notifier).byName(chatId);
        if (channel == null) return;
        final frame = await _buildChannelFrame(
          channel,
          InnerPayloadType.edit,
          body,
          TransportEnvelope.newMsgId(initialTtl: _meshTtl),
        );
        await _broadcastChannelFrame(frame);
      } else {
        final peerPub = _resolvePeerPub(chatId);
        if (peerPub == null) return;
        await _sendControlToPeer(
          canonicalId: chatId,
          peerPub: peerPub,
          type: InnerPayloadType.edit,
          innerBody: body,
        );
      }
    } catch (e) {
      DebugLog.instance.log('EDIT', 'edit send failed: $e');
    }
  }

  /// Retract one of our own already-sent messages everywhere: drop it locally
  /// and tell the other side(s) to drop it too. No-op when [targetWireId]
  /// doesn't name a message of ours.
  Future<void> sendDeleteForEveryone(
    String chatId,
    String targetWireId,
  ) async {
    final Uint8List target;
    try {
      target = _hexDecodeBytes(targetWireId);
    } catch (_) {
      return;
    }
    if (target.length != MessageDelete.idLen) return;

    final messages = _ref.read(messagesControllerProvider.notifier);
    if (!messages.deleteMineByWireId(chatId, targetWireId)) return;

    final body = MessageDelete(targetMsgId: target).encode();
    try {
      if (chatId.startsWith('#')) {
        final channel =
            _ref.read(channelControllerProvider.notifier).byName(chatId);
        if (channel == null) return;
        final frame = await _buildChannelFrame(
          channel,
          InnerPayloadType.delete,
          body,
          TransportEnvelope.newMsgId(initialTtl: _meshTtl),
        );
        await _broadcastChannelFrame(frame);
      } else {
        final peerPub = _resolvePeerPub(chatId);
        if (peerPub == null) return;
        await _sendControlToPeer(
          canonicalId: chatId,
          peerPub: peerPub,
          type: InnerPayloadType.delete,
          innerBody: body,
        );
      }
    } catch (e) {
      DebugLog.instance.log('EDIT', 'delete send failed: $e');
    }
  }

  /// Pin (or unpin) a message for everyone in [chatId], referenced by its
  /// [targetWireId]. Applies locally first so the banner appears instantly, then
  /// mirrors it to the other side over the same signed + encrypted control path
  /// a reaction uses.
  ///
  /// Either party may pin any message in the chat — including one the *other*
  /// person sent, which is the common case ("pin the address he just sent").
  /// That's why there's no author check here or on the receiving side; the pin
  /// is conversation state, not a rewrite of somebody's message.
  Future<void> sendPin(
    String chatId,
    String targetWireId, {
    required bool pinned,
  }) async {
    final Uint8List target;
    try {
      target = _hexDecodeBytes(targetWireId);
    } catch (_) {
      return;
    }
    if (target.length != MessagePin.idLen) return;

    final pins = _ref.read(pinnedControllerProvider.notifier);
    if (pinned) {
      await pins.pin(chatId, targetWireId);
    } else {
      await pins.unpin(chatId, wireId: targetWireId);
    }

    final body = MessagePin(
      op: pinned ? PinOp.pin : PinOp.unpin,
      targetMsgId: target,
    ).encode();
    try {
      if (chatId.startsWith('#')) {
        final channel =
            _ref.read(channelControllerProvider.notifier).byName(chatId);
        if (channel == null) return;
        final frame = await _buildChannelFrame(
          channel,
          InnerPayloadType.pin,
          body,
          TransportEnvelope.newMsgId(initialTtl: _meshTtl),
        );
        await _broadcastChannelFrame(frame);
      } else {
        final peerPub = _resolvePeerPub(chatId);
        if (peerPub == null) return;
        await _sendControlToPeer(
          canonicalId: chatId,
          peerPub: peerPub,
          type: InnerPayloadType.pin,
          innerBody: body,
        );
      }
    } catch (e) {
      DebugLog.instance.log('PIN', 'pin send failed: $e');
    }
  }

  /// A pin/unpin from the other side of a 1:1 chat, applied to the same buckets
  /// their messages land in.
  void _ingestPeerPin({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final MessagePin p;
    try {
      p = MessagePin.decode(body);
    } catch (e) {
      DebugLog.instance.log('PIN', 'drop pin from $peerId: $e');
      return;
    }
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    final target = TransportEnvelope.hashHex(p.targetMsgId);
    final buckets =
        canonical != peerId ? <String>[canonical, peerId] : <String>[canonical];
    _applyPinToBuckets(buckets, target: target, pinned: p.op == PinOp.pin);
  }

  void _applyPinToBuckets(
    List<String> buckets, {
    required String target,
    required bool pinned,
  }) {
    final pins = _ref.read(pinnedControllerProvider.notifier);
    for (final b in buckets) {
      if (pinned) {
        unawaited(pins.pin(b, target));
      } else {
        unawaited(pins.unpin(b, wireId: target));
      }
    }
    DebugLog.instance
        .log('PIN', '${pinned ? 'pinned' : 'unpinned'} $target from peer');
  }

  /// An inbound "delete for everyone" from a peer, applied to their message.
  void _ingestPeerDelete({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final MessageDelete del;
    try {
      del = MessageDelete.decode(body);
    } catch (e) {
      DebugLog.instance.log('EDIT', 'drop delete from $peerId: $e');
      return;
    }
    final target = TransportEnvelope.hashHex(del.targetMsgId);
    final messages = _ref.read(messagesControllerProvider.notifier);
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    messages.deleteFromPeer(canonical, target);
    if (canonical != peerId) messages.deleteFromPeer(peerId, target);
  }

  /// An inbound edit from a peer, applied to their own message only.
  void _ingestPeerEdit({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final MessageEdit edit;
    try {
      edit = MessageEdit.decode(body);
    } catch (e) {
      DebugLog.instance.log('EDIT', 'drop edit from $peerId: $e');
      return;
    }
    final target = TransportEnvelope.hashHex(edit.targetMsgId);
    final messages = _ref.read(messagesControllerProvider.notifier);
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    messages.editFromPeer(canonical, target, edit.text);
    if (canonical != peerId) {
      messages.editFromPeer(peerId, target, edit.text);
    }
  }

  /// Hand [peerCanonicalId] the key to a channel we're a member of, over the
  /// 1:1 signed + SealedBox path. Returns the number of links the invite went
  /// out on — 0 means the peer is unreachable right now and nothing was sent.
  ///
  /// Throws [StateError] when we aren't in the channel or don't know the peer,
  /// and [FormatException] when the channel name is too long for one frame.
  Future<int> sendChannelInvite({
    required String channelName,
    required String peerCanonicalId,
  }) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) {
      throw StateError('not a member of $channelName');
    }
    final peerPub = _resolvePeerPub(peerCanonicalId);
    if (peerPub == null) {
      throw StateError('no pubkey for peer $peerCanonicalId');
    }
    final body = ChannelInvite(name: channel.name, key: channel.key).encode();
    final fanout = await _sendControlToPeer(
      canonicalId: peerCanonicalId,
      peerPub: peerPub,
      type: InnerPayloadType.channelInvite,
      innerBody: body,
    );
    DebugLog.instance.log('CHAN',
        'invite to ${channel.name} → $peerCanonicalId (fanout=$fanout)');
    return fanout;
  }

  /// A peer handed us a channel key — join it and surface it in the chat list.
  ///
  /// Guarded twice, because SealedBox is anonymous: anyone who knows our public
  /// key can encrypt to us. We therefore accept an invite only when it carries
  /// a valid Ed25519 signature *and* that signing key already belongs to a peer
  /// in our roster. Without both, any node on the mesh could silently push
  /// channels into the user's chat list.
  Future<void> _ingestChannelInvite({
    required String peerId,
    required Uint8List? senderEdPub,
    required Uint8List body,
  }) async {
    if (senderEdPub == null) {
      DebugLog.instance
          .log('CHAN', 'drop channel invite from $peerId: not signed');
      return;
    }
    final inviter = _knownPeerBySignKey(senderEdPub);
    if (inviter == null) {
      DebugLog.instance.log('CHAN',
          'drop channel invite from $peerId: signer is not a known peer');
      return;
    }
    final ChannelInvite invite;
    try {
      invite = ChannelInvite.decode(body);
    } catch (e) {
      DebugLog.instance
          .log('CHAN', 'drop channel invite from $peerId: malformed ($e)');
      return;
    }
    try {
      final channel = await _ref
          .read(channelControllerProvider.notifier)
          .joinWithKey(invite.name, invite.key);
      final roster = _ref.read(channelRosterControllerProvider.notifier);
      await roster.record(
        channel.name,
        ChannelMember(
          id: _hexOf(senderEdPub).substring(0, 16),
          name: inviter.displayName,
          isAdmin: true,
          lastSeen: DateTime.now(),
        ),
      );
      DebugLog.instance.log('CHAN',
          'auto-joined ${channel.name} on invite from ${inviter.displayName}');
      if (!AppLifecycle.instance.isViewingChat(channel.name)) {
        unawaited(NotificationService.instance.showMessage(
          threadKey: channel.name,
          title: channel.name,
          body: '${inviter.displayName} added you to this channel',
          senderId: channel.name,
          isGroup: true,
        ));
      }
      await roster.ensureSelf(channel.name);
    } catch (e) {
      DebugLog.instance.log('CHAN', 'channel invite join failed: $e');
    }
  }

  /// The roster entry whose Ed25519 signing key is [edPub], or null.
  KnownPeer? _knownPeerBySignKey(Uint8List edPub) {
    for (final p in _ref.read(knownPeersControllerProvider).values) {
      final pub = p.signPublicKey;
      if (pub != null && _bytesEqual(pub, edPub)) return p;
    }
    return null;
  }

  /// Post [text] to a joined channel. Encrypted under the shared channel key
  /// and broadcast across the mesh; every member with the key decrypts it.
  /// Returns the local pending Message (bucketed under the channel name).
  Future<Message> sendChannelText(String channelName, String text) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) {
      throw StateError('not a member of $channelName');
    }
    await _ref
        .read(channelRosterControllerProvider.notifier)
        .ensureSelf(channel.name, adminWhenFirst: true);
    final canonicalId = channel.name;
    final msgId = TransportEnvelope.newMsgId(initialTtl: _meshTtl);
    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: canonicalId,
      text: text,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      wireId: TransportEnvelope.hashHex(msgId),
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);

    try {
      final utf8Text = Uint8List.fromList(utf8.encode(text));
      final inner = padTextPayload(utf8Text);
      final frame = await _buildChannelFrame(
          channel, InnerPayloadType.text, inner, msgId);
      final fanout = await _broadcastChannelFrame(frame);
      messages.updateStatus(
        canonicalId,
        msg.id,
        fanout > 0 ? MessageStatus.delivered : MessageStatus.sending,
      );
      DebugLog.instance
          .log('CHAN', 'channel post to ${channel.name} fanout=$fanout');
      messages.updateRoute(
        canonicalId,
        msg.id,
        fanout > 0 ? MessageRoute.mesh : MessageRoute.queued,
      );
    } catch (e, st) {
      debugPrint('sendChannelText failed: $e\n$st');
      messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
    }
    return msg;
  }

  /// Post a photo to a joined channel.
  ///
  /// Same two-part shape as the 1:1 photo — a manifest committing to the size,
  /// mime and SHA-256, then the chunks — but sealed under the channel key and
  /// broadcast instead of sealed to one recipient. There is no addressee to
  /// derive a forward-secret media key with, and no route to fall back to per
  /// peer: everyone in the room decrypts the same bytes off the same broadcast.
  ///
  /// Chunks are sized for the conservative MTU rather than a link's negotiated
  /// one, because a broadcast has no single link to size against — the same
  /// frame has to survive the narrowest hop in the room.
  Future<Message> sendChannelImage(
    String channelName, {
    required Uint8List bytes,
    required String mime,
    String? cachedPath,
    String? caption,
  }) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    await _ref
        .read(channelRosterControllerProvider.notifier)
        .ensureSelf(channel.name, adminWhenFirst: true);

    final imageId = ImageChunk.newImageId();
    final caption0 = (caption?.trim().isEmpty ?? true) ? null : caption!.trim();
    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: channel.name,
      text: caption0 ?? mime,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      kind: MessageKind.image,
      imagePath: cachedPath,
      imageMime: mime,
      wireId: TransportEnvelope.hashHex(imageId),
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(channel.name, msg);

    try {
      final relayOnly = !_hasAnyLink;
      final chunkData = _mediaChunkData(null,
          relayOnly: relayOnly, ceiling: ImageChunk.maxDataBytes);
      final total = (bytes.length + chunkData - 1) ~/ chunkData;
      if (total < 1 || total > ImageChunk.maxChunks) {
        throw StateError(
          'image too large: $total chunks > ${ImageChunk.maxChunks} cap',
        );
      }
      final sha = Uint8List.fromList((await Sha256().hash(bytes)).bytes);
      final manifest = MediaManifest(
        mediaId: imageId,
        kind: MediaKind.image,
        total: total,
        mime: mime,
        durationMs: 0,
        caption: caption0,
        sha256: sha,
      );
      var fanout = await _broadcastChannelFrame(
        await _buildChannelFrame(
          channel,
          InnerPayloadType.mediaManifest,
          manifest.encode(),
          TransportEnvelope.newMsgId(initialTtl: _meshTtl),
        ),
      );
      for (var i = 0; i < total; i++) {
        final start = i * chunkData;
        final end = (start + chunkData).clamp(0, bytes.length);
        final chunk = ImageChunk(
          imageId: imageId,
          seq: i,
          total: total,
          mime: mime,
          data: Uint8List.fromList(bytes.sublist(start, end)),
        );
        fanout = await _broadcastChannelFrame(
          await _buildChannelFrame(
            channel,
            InnerPayloadType.imageChunk,
            chunk.encode(),
            TransportEnvelope.newMsgId(initialTtl: _meshTtl),
          ),
        );
        // Same pacing as the 1:1 photo path — see [sendImage].
        if (i + 1 < total && !relayOnly) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
      }
      DebugLog.instance.log('CHAN',
          'channel photo to ${channel.name}: $total chunks, fanout=$fanout');
      messages.updateStatus(
        channel.name,
        msg.id,
        fanout > 0 ? MessageStatus.delivered : MessageStatus.sending,
      );
      messages.updateRoute(
        channel.name,
        msg.id,
        fanout > 0 ? MessageRoute.mesh : MessageRoute.queued,
      );
    } catch (e, st) {
      debugPrint('sendChannelImage failed: $e\n$st');
      messages.updateStatus(channel.name, msg.id, MessageStatus.failed);
      rethrow;
    }
    return msg;
  }

  /// Set (or, with a null [jpeg], clear) the room's picture for everyone.
  ///
  /// Refused locally when we are not an admin. That check is a courtesy to the
  /// person tapping — the one that matters runs on every receiver, against
  /// their own roster, because our own copy of it is not evidence of anything.
  Future<void> sendChannelAvatar(String channelName, Uint8List? jpeg) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    if (!roster.isAdmin(channel.name, me.id)) {
      throw StateError('only an admin can set the picture for $channelName');
    }
    final avatars = _ref.read(channelAvatarsControllerProvider.notifier);
    await avatars.loaded;
    if (jpeg == null) {
      await avatars.forget(channel.name);
    } else if (!await avatars.store(channel.name, jpeg)) {
      throw StateError('picture is too large for one frame');
    }
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.channelAvatar,
      jpeg == null ? Uint8List(0) : AvatarPayload(jpeg: jpeg).encode(),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    final fanout = await _broadcastChannelFrame(frame);
    DebugLog.instance.log('CHAN',
        'channel picture for ${channel.name}: ${jpeg?.length ?? 0}B, fanout=$fanout');
  }

  /// Set (or, with an empty [text], clear) the room's topic for everyone.
  ///
  /// Same shape and the same trust model as [sendChannelAvatar]: refused
  /// locally when we are not an admin, which is a courtesy to the person
  /// tapping — the check that matters runs on every receiver against their own
  /// roster.
  Future<void> sendChannelDescription(String channelName, String text) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    if (!roster.isAdmin(channel.name, me.id)) {
      throw StateError('only an admin can set the topic for $channelName');
    }
    final trimmed = text.trim();
    final descriptions =
        _ref.read(channelDescriptionsControllerProvider.notifier);
    await descriptions.loaded;
    if (!await descriptions.store(channel.name, trimmed)) {
      throw StateError('topic is too long');
    }
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.channelDescription,
      Uint8List.fromList(utf8.encode(trimmed)),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    final fanout = await _broadcastChannelFrame(frame);
    DebugLog.instance.log('CHAN',
        'channel topic for ${channel.name}: ${trimmed.length} chars, fanout=$fanout');
  }

  /// Publishes a signed poll to a joined channel.
  Future<Message> sendChannelPoll(
    String channelName,
    String question,
    List<String> options,
  ) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final payload = ChannelPollPayload.create(question, options);
    await _ref
        .read(channelRosterControllerProvider.notifier)
        .ensureSelf(channel.name, adminWhenFirst: true);

    final msgId = TransportEnvelope.newMsgId(initialTtl: _meshTtl);
    final message = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: channel.name,
      text: payload.question!,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      kind: MessageKind.poll,
      wireId: TransportEnvelope.hashHex(msgId),
      pollOptions: payload.options,
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(channel.name, message);
    try {
      final frame = await _buildChannelFrame(
        channel,
        InnerPayloadType.channelPoll,
        payload.encode(),
        msgId,
      );
      final fanout = await _broadcastChannelFrame(frame);
      messages.updateStatus(
        channel.name,
        message.id,
        fanout > 0 ? MessageStatus.delivered : MessageStatus.sending,
      );
      messages.updateRoute(
        channel.name,
        message.id,
        fanout > 0 ? MessageRoute.mesh : MessageRoute.queued,
      );
    } catch (error) {
      messages.updateStatus(channel.name, message.id, MessageStatus.failed);
      rethrow;
    }
    return message;
  }

  /// Casts or changes the local user's vote and broadcasts the signed choice.
  Future<void> sendChannelPollVote(
    String channelName,
    String pollWireId,
    int option,
  ) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final payload = ChannelPollPayload.vote(pollWireId, option);
    _ref.read(messagesControllerProvider.notifier).applyPollVote(
          channel.name,
          pollWireId: pollWireId,
          voterId: 'me',
          option: option,
        );
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.channelPoll,
      payload.encode(),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    await _broadcastChannelFrame(frame);
  }

  /// Changes an administrator role locally and broadcasts the signed change.
  /// Only a signer already known as an administrator may create the event.
  Future<void> sendChannelAdminChange(
    String channelName,
    String memberId,
    bool isAdmin,
  ) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    if (!roster.isAdmin(channel.name, me.id)) {
      throw StateError('administrator permission required');
    }
    final change = ChannelAdminChange(memberId: memberId, isAdmin: isAdmin);
    await roster.setAdmin(channel.name, memberId, isAdmin);
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.channelAdmin,
      change.encode(),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    await _broadcastChannelFrame(frame);
  }

  /// Sign + SealedBox-encrypt a small control payload (read receipt /
  /// reaction) to a single peer and deliver it best-effort (direct session,
  /// else mesh fan-out — no store-and-forward hold; a receipt/reaction that
  /// misses isn't worth persisting). Returns the number of links it went out
  /// on.
  ///
  /// [relayOnly] skips the mesh entirely and publishes over Nostr alone — for
  /// the presence heartbeat, whose whole job is covering peers the mesh can't
  /// see, and which must not spend BLE airtime on the ones it can.
  Future<int> _sendControlToPeer({
    required String canonicalId,
    required Uint8List peerPub,
    required InnerPayloadType type,
    required Uint8List innerBody,
    bool relayOnly = false,
  }) async {
    final identity = await _ref.read(identityProvider.future);
    final myHash = await _myPubkeyHash();
    final peerHash = await _peerPubkeyHash(peerPub);
    final msgId = TransportEnvelope.newMsgId(initialTtl: _meshTtl);
    final ctx = SignedPayload.contextBytes(
      originPubkeyHash: myHash,
      destPubkeyHash: peerHash,
      msgId: msgId,
    );
    final inner = packInnerPayload(type, innerBody);
    final signed = await SignedPayload.wrap(
      inner: inner,
      context: ctx,
      signKeyPair: identity.asSignKeyPair(),
      senderEdPub: identity.signPublicKey,
    );
    final body =
        _tagBody(_cipherSealedBox, await SealedBox.seal(signed, peerPub));
    final env = TransportEnvelope(
      originPubkeyHash: myHash,
      destPubkeyHash: peerHash,
      msgId: msgId,
      ttl: _meshTtl,
      body: body,
    );
    _dedup.acceptEnvelope(env);
    final frameBytes =
        Frame(type: FrameType.transport, payload: env.encode()).encode();

    if (relayOnly) {
      return await _sendOverNostr(canonicalId, frameBytes) ? 1 : 0;
    }

    final session = _findSessionByPubkeyHex(canonicalId);
    final transportId = session?.peerId;
    if (transportId != null) {
      final client = _clients[transportId];
      if (client != null && client.isConnected) {
        try {
          await _writeFrameToClient(client, frameBytes);
          return 1;
        } catch (_) {/* fall through to notify / fan-out */}
      }
      try {
        if (await _notifyFrameToPeripheral(frameBytes)) {
          return 1;
        }
      } catch (_) {}
    }
    final fanout = await _fanoutAllLinks(frameBytes, excludePeerId: null);
    if (fanout > 0) return fanout;
    // Same internet fallback as sendText: a receipt or reaction the mesh can't
    // deliver still reaches a peer who's only on relays.
    return await _sendOverNostr(canonicalId, frameBytes) ? 1 : 0;
  }

  /// Build a broadcast channel frame: sign the inner payload (full signature,
  /// so members learn the author's Ed25519 key), encrypt it under the channel
  /// key, prepend the public channel tag + cipher tag, and wrap in a
  /// broadcast [TransportEnvelope]. Pre-records the msgId in the dedup cache
  /// so our own copy bouncing back over a relay is ignored.
  Future<Uint8List> _buildChannelFrame(
    Channel channel,
    InnerPayloadType type,
    Uint8List innerBody,
    Uint8List msgId,
  ) async {
    final identity = await _ref.read(identityProvider.future);
    final myHash = await _myPubkeyHash();
    final broadcast = TransportEnvelope.broadcastDest();
    final inner = packInnerPayload(type, innerBody);
    final ctx = SignedPayload.contextBytes(
      originPubkeyHash: myHash,
      destPubkeyHash: broadcast,
      msgId: msgId,
    );
    final signed = await SignedPayload.wrap(
      inner: inner,
      context: ctx,
      signKeyPair: identity.asSignKeyPair(),
      senderEdPub: identity.signPublicKey,
    );
    final sealed = await ChannelCrypto.seal(channel.key, signed);
    final channelBody = Uint8List(ChannelCrypto.tagLen + sealed.length)
      ..setRange(0, ChannelCrypto.tagLen, channel.tag)
      ..setRange(
          ChannelCrypto.tagLen, ChannelCrypto.tagLen + sealed.length, sealed);
    final env = TransportEnvelope(
      originPubkeyHash: myHash,
      destPubkeyHash: broadcast,
      msgId: msgId,
      ttl: _meshTtl,
      body: _tagBody(_cipherChannel, channelBody),
    );
    _dedup.acceptEnvelope(env);
    return Frame(type: FrameType.transport, payload: env.encode()).encode();
  }

  /// Put a channel frame in front of everyone in the room — over the mesh and
  /// over the internet both.
  ///
  /// A channel is a broadcast with no addressee: on BLE it goes onto every link
  /// and members pick it out by matching the 8-byte channel tag, while everyone
  /// else forwards it without being able to open it. Nostr has no broadcast, so
  /// the same shape is reproduced by publishing to each known peer's `npub` —
  /// same audience, same rule for non-members (the tag matches no channel of
  /// theirs, and the body is noise without the key).
  ///
  /// The two paths are **additive, not a fallback**. For a 1:1 message the relay
  /// is a second attempt at one person, so a delivered BLE write ends it. A room
  /// is different: the member sitting next to you and the member in another city
  /// are disjoint sets, and stopping because the mesh accepted the frame is
  /// exactly the bug where a channel post reached nobody who wasn't in radio
  /// range.
  ///
  /// Capped and paced, because relays rate-limit: a burst of publishes earns a
  /// `rate-limited` that lands on real messages too.
  Future<int> _broadcastChannelFrame(Uint8List frameBytes) async {
    final mesh = await _fanoutAllLinks(frameBytes, excludePeerId: null);
    final relayed = await _broadcastChannelOverNostr(frameBytes);
    return mesh + relayed;
  }

  Future<int> _broadcastChannelOverNostr(
    Uint8List frameBytes, {
    String? excludePubkeyHex,
  }) async {
    if (_nostr == null) return 0;
    final now = DateTime.now();
    final peers = _ref
        .read(knownPeersControllerProvider)
        .values
        .where((p) =>
            p.nostrPubkey != null &&
            !p.isBlocked &&
            p.pubkeyHex != excludePubkeyHex &&
            now.difference(p.lastSeen) < _presenceMaxPeerAge)
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    if (peers.isEmpty) return 0;

    final targets = peers.take(_channelFanoutCap).toList();
    var sent = 0;
    for (var i = 0; i < targets.length; i++) {
      try {
        if (await _sendOverNostr(targets[i].pubkeyHex, frameBytes)) sent++;
      } catch (e) {
        DebugLog.instance.log('CHAN', 'relay post failed: $e');
      }
      if (i + 1 < targets.length) {
        await Future<void>.delayed(relayFanoutPacing);
      }
    }
    if (sent > 0) {
      DebugLog.instance.log('CHAN', 'channel post relayed to $sent peer(s)');
    }
    return sent;
  }

  /// Pass a room frame we just received on to *our* contacts over the relay.
  ///
  /// The mesh forwards a broadcast on every BLE link it holds, but the relay
  /// path had no equivalent: [_broadcastChannelOverNostr] publishes to the
  /// author's own known peers and nobody else, and a member who received the
  /// frame re-emitted it over Bluetooth only. In a three-person room where A
  /// and C have never met — they were each invited by B — that is exactly the
  /// bug people hit: C sees everything B writes and nothing A writes, because
  /// A has no npub to publish to for C and B never carried it across.
  ///
  /// So a member relays too. Only members: the frame is opaque to everyone
  /// else, and having non-members spray unreadable traffic at their contacts
  /// would be bandwidth spent on nothing. The ttl is decremented like any mesh
  /// hop and the flood terminates on the (origin, msgId) dedup every node
  /// already applies — including the author, who pre-records their own msgId,
  /// so a frame coming back around is dropped rather than re-relayed.
  Future<void> _relayChannelFrameOverNostr(TransportEnvelope env) async {
    if (_nostr == null) return;
    final relayed = env.decrementTtl();
    if (relayed.ttl <= 0) return;
    // Don't bounce it straight back at whoever we can identify as the author.
    String? originHex;
    try {
      final originPub = await _peerForId(env.originPubkeyHash);
      if (originPub != null) originHex = _hexOf(originPub);
    } catch (_) {
      // Unknown origin — the dedup on their side handles the echo.
    }
    final bytes =
        Frame(type: FrameType.transport, payload: relayed.encode()).encode();
    final sent = await _broadcastChannelOverNostr(
      bytes,
      excludePubkeyHex: originHex,
    );
    if (sent > 0) {
      DebugLog.instance.log(
          'CHAN', 'room frame carried on to $sent peer(s) ttl=${relayed.ttl}');
    }
  }

  /// Decrypt + route an inbound channel broadcast. The frame has already been
  /// dedup-checked and relayed by [_handleTransportFrame]; here we pick the
  /// matching joined channel by its public tag, open it, verify the author's
  /// signature, and append the message / apply the reaction to the channel's
  /// bucket. Frames for channels we haven't joined are silently dropped (we
  /// still relayed them onward for members downstream).
  Future<void> _handleChannelBody({
    required TransportEnvelope env,
    required String peerId,
    required Uint8List channelBody,
  }) async {
    if (channelBody.length < ChannelCrypto.tagLen) {
      DebugLog.instance.log('CHAN', 'drop channel frame: truncated');
      return;
    }
    final tag =
        Uint8List.fromList(channelBody.sublist(0, ChannelCrypto.tagLen));
    final channel =
        _ref.read(channelControllerProvider.notifier).channelForTag(tag);
    if (channel == null) return; // not a member — relayed only

    // Skip our own broadcast reflected back through a relay.
    final myHash = await _myPubkeyHash();
    if (_bytesEqual(env.originPubkeyHash, myHash)) return;

    // We are in this room, so we are also a route into it for the members we
    // know and the author may not. Fired before the frame is opened: whether
    // it decrypts, verifies or turns out to be a payload we don't understand
    // is our business, not the next member's.
    unawaited(_relayChannelFrameOverNostr(env));

    final blob = Uint8List.fromList(channelBody.sublist(ChannelCrypto.tagLen));
    final Uint8List plain;
    try {
      plain = await ChannelCrypto.open(channel.key, blob);
    } catch (e) {
      DebugLog.instance.log('CHAN',
          'drop ${channel.name} frame: decrypt failed (wrong password?)');
      return;
    }

    if (plain.isEmpty || plain[0] != SignedPayload.markerByte) {
      DebugLog.instance
          .log('CHAN', 'drop ${channel.name} frame: not author-signed');
      return;
    }
    final ctx = SignedPayload.contextBytes(
      originPubkeyHash: env.originPubkeyHash,
      destPubkeyHash: env.destPubkeyHash,
      msgId: env.msgId,
    );
    final Uint8List innerBytes;
    final Uint8List senderEdPub;
    try {
      final expectedEd = await _expectedEdPubFor(env.originPubkeyHash);
      final verified = await SignedPayload.verify(
        wire: plain,
        context: ctx,
        expectedEdPub: expectedEd,
      );
      if (!_freshEnough(verified.timestampMs, peerId)) return;
      innerBytes = verified.inner;
      senderEdPub = verified.senderEdPub;
      await _maybeCacheSignerForOrigin(
        originHash: env.originPubkeyHash,
        edPub: senderEdPub,
      );
    } on SignatureVerificationException catch (e) {
      DebugLog.instance.log(
          'CHAN', 'drop ${channel.name} frame: bad signature (${e.message})');
      return;
    }

    try {
      final unpacked = unpackInnerPayload(innerBytes);
      final authorName = _resolveAuthorName(senderEdPub);
      final reactorId = _hexOf(senderEdPub).substring(0, 16);
      await _ref.read(channelRosterControllerProvider.notifier).record(
            channel.name,
            ChannelMember(
              id: reactorId,
              name: authorName,
              isAdmin: false,
              lastSeen: DateTime.now(),
            ),
          );
      final incomingHops = peerId == _nostrPeerId ? null : env.traversedHops;
      switch (unpacked.type) {
        case InnerPayloadType.text:
          final plaintext = utf8.decode(
            unpadTextPayload(unpacked.body),
            allowMalformed: true,
          );
          final message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: channel.name,
            text: plaintext,
            sentAt: DateTime.now(),
            isMine: false,
            wireId: TransportEnvelope.hashHex(env.msgId),
            authorName: authorName,
            // The fingerprint, not the name: an inbound edit is checked
            // against it, and display names are not identities.
            authorId: reactorId,
            route: peerId == _nostrPeerId
                ? MessageRoute.internet
                : (incomingHops ?? 2) > 1
                    ? MessageRoute.mesh
                    : MessageRoute.bluetooth,
            routeHops: incomingHops,
          );
          // append() is idempotent on wireId; only a genuinely new message
          // warrants a notification.
          if (_ref
              .read(messagesControllerProvider.notifier)
              .append(channel.name, message)) {
            _notifyChannel(
                channel: channel, authorName: authorName, message: message);
          }

        case InnerPayloadType.textReply:
          final reply = unpackTextReply(unpacked.body);
          final plaintext = utf8.decode(
            unpadTextPayload(reply.paddedText),
            allowMalformed: true,
          );
          final message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: channel.name,
            text: plaintext,
            sentAt: DateTime.now(),
            isMine: false,
            wireId: TransportEnvelope.hashHex(env.msgId),
            authorName: authorName,
            authorId: reactorId,
            replyToWireId: TransportEnvelope.hashHex(reply.targetMsgId),
            route: peerId == _nostrPeerId
                ? MessageRoute.internet
                : (incomingHops ?? 2) > 1
                    ? MessageRoute.mesh
                    : MessageRoute.bluetooth,
            routeHops: incomingHops,
          );
          if (_ref
              .read(messagesControllerProvider.notifier)
              .append(channel.name, message)) {
            _notifyChannel(
                channel: channel, authorName: authorName, message: message);
          }

        case InnerPayloadType.reaction:
          final rx = Reaction.decode(unpacked.body);
          _applyReactionToBuckets([channel.name], rx: rx, reactorId: reactorId);

        case InnerPayloadType.edit:
          final edit = MessageEdit.decode(unpacked.body);
          // reactorId is the signer's key fingerprint, and only the author of
          // the target message may rewrite it.
          _ref.read(messagesControllerProvider.notifier).editFromPeer(
                channel.name,
                TransportEnvelope.hashHex(edit.targetMsgId),
                edit.text,
                authorId: reactorId,
              );

        case InnerPayloadType.delete:
          final del = MessageDelete.decode(unpacked.body);
          _ref.read(messagesControllerProvider.notifier).deleteFromPeer(
                channel.name,
                TransportEnvelope.hashHex(del.targetMsgId),
                authorId: reactorId,
              );

        case InnerPayloadType.pin:
          final pin = MessagePin.decode(unpacked.body);
          // Any member may pin in a channel, so no author guard (see sendPin).
          _applyPinToBuckets(
            [channel.name],
            target: TransportEnvelope.hashHex(pin.targetMsgId),
            pinned: pin.op == PinOp.pin,
          );

        case InnerPayloadType.receipt:
          // Symmetric with the 1:1 path: withholding your own receipts also
          // gives up watching other people's.
          if (_ref.read(privacySettingsProvider).shareReadReceipts) {
            _ingestChannelReceipt(
              channel: channel,
              readerId: reactorId,
              readerName: authorName,
              body: unpacked.body,
            );
          }

        case InnerPayloadType.channelPoll:
          final poll = ChannelPollPayload.decode(unpacked.body);
          if (poll.operation == ChannelPollOperation.create) {
            final message = Message(
              id: 'm${DateTime.now().microsecondsSinceEpoch}',
              chatId: channel.name,
              text: poll.question!,
              sentAt: DateTime.now(),
              isMine: false,
              kind: MessageKind.poll,
              wireId: TransportEnvelope.hashHex(env.msgId),
              authorName: authorName,
              authorId: reactorId,
              pollOptions: poll.options,
              route: peerId == _nostrPeerId
                  ? MessageRoute.internet
                  : (incomingHops ?? 2) > 1
                      ? MessageRoute.mesh
                      : MessageRoute.bluetooth,
              routeHops: incomingHops,
            );
            if (_ref
                .read(messagesControllerProvider.notifier)
                .append(channel.name, message)) {
              _notifyChannel(
                channel: channel,
                authorName: authorName,
                message: message,
              );
            }
          } else {
            _ref.read(messagesControllerProvider.notifier).applyPollVote(
                  channel.name,
                  pollWireId: poll.targetWireId!,
                  voterId: reactorId,
                  option: poll.option!,
                );
          }
        case InnerPayloadType.channelAdmin:
          final change = ChannelAdminChange.decode(unpacked.body);
          final roster = _ref.read(channelRosterControllerProvider.notifier);
          if (roster.isAdmin(channel.name, reactorId)) {
            await roster.setAdmin(
              channel.name,
              change.memberId,
              change.isAdmin,
            );
          }

        case InnerPayloadType.channelAvatar:
          // The authorisation, and the only one that counts: the frame's
          // signature says who sent it, and our own roster says whether they
          // are allowed to change what the room looks like.
          if (!_ref
              .read(channelRosterControllerProvider.notifier)
              .isAdmin(channel.name, reactorId)) {
            DebugLog.instance.log('CHAN',
                'drop ${channel.name} picture: $reactorId is not an admin');
            break;
          }
          final avatars = _ref.read(channelAvatarsControllerProvider.notifier);
          await avatars.loaded;
          if (unpacked.body.isEmpty) {
            await avatars.forget(channel.name);
          } else {
            await avatars.store(
              channel.name,
              AvatarPayload.decode(unpacked.body).jpeg,
            );
          }

        case InnerPayloadType.channelDescription:
          // Same authorisation as the picture, and for the same reason: the
          // signature says who sent it, our roster says whether they may.
          if (!_ref
              .read(channelRosterControllerProvider.notifier)
              .isAdmin(channel.name, reactorId)) {
            DebugLog.instance.log('CHAN',
                'drop ${channel.name} topic: $reactorId is not an admin');
            break;
          }
          final descriptions =
              _ref.read(channelDescriptionsControllerProvider.notifier);
          await descriptions.loaded;
          await descriptions.store(
            channel.name,
            utf8.decode(unpacked.body, allowMalformed: true),
          );
        // Photos in a room. The manifest commits to the byte count and the
        // SHA-256, and it arrived inside a frame the channel signature already
        // authenticated — so unlike the 1:1 path there is no second signature
        // to check here, and unlike it there is no addressee: everyone holding
        // the key reassembles the same picture.
        case InnerPayloadType.mediaManifest:
          await _ingestChannelManifest(
            channel: channel,
            authorName: authorName,
            authorId: reactorId,
            manifestBytes: unpacked.body,
          );

        case InnerPayloadType.imageChunk:
          await _ingestImageChunk(
            peerId: channel.name,
            senderPub: null,
            chunkBytes: unpacked.body,
          );

        case InnerPayloadType.channelInvite:
        case InnerPayloadType.audioChunk:
        case InnerPayloadType.fileChunk:
        case InnerPayloadType.presence:
        case InnerPayloadType.avatarRequest:
        case InnerPayloadType.avatar:
        case InnerPayloadType.mediaRequest:
        case InnerPayloadType.viewOnceConsumed:
        case InnerPayloadType.typing:
        case InnerPayloadType.conversationClear:
          // Not carried in channels — ignore. (An invite is addressed to one
          // peer; broadcasting one to the channel would be circular, presence
          // is per-peer, an avatar answers a request from one peer — a
          // channel-wide broadcast of a picture is a fan-out nobody asked for —
          // and a request for a file again has no single member to answer it.)
          break;
      }
    } catch (e) {
      DebugLog.instance
          .log('CHAN', 'drop ${channel.name} frame: malformed inner ($e)');
    }
  }

  /// A read receipt from a peer flips our matching outgoing messages to read.
  void _ingestReceipt({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final ReadReceipt r;
    try {
      r = ReadReceipt.decode(body);
    } catch (e) {
      DebugLog.instance.log('RECEIPT', 'drop receipt from $peerId: $e');
      return;
    }
    if (r.status != ReceiptStatus.read) return;
    final ids = r.msgIds.map(TransportEnvelope.hashHex).toSet();
    final messages = _ref.read(messagesControllerProvider.notifier);
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    messages.markRead(canonical, ids);
    if (canonical != peerId) messages.markRead(peerId, ids);
  }

  /// The channel counterpart: record *who* read, rather than flipping a status.
  ///
  /// A 1:1 receipt can move [MessageStatus.read] because there is only one
  /// person it could have come from. A channel has as many readers as hold the
  /// key and no roster to enumerate them, so the answer to "has this been read"
  /// is a list of the people who said so — accumulated per reader, exactly the
  /// way reactions accumulate per reactor.
  ///
  /// [readerId] and [readerName] are the ones [_handleChannelBody] already
  /// derived from the frame's signature, so identity here is as strong as it is
  /// for authorship: a relay cannot invent a reader.
  void _ingestChannelReceipt({
    required Channel channel,
    required String readerId,
    required String readerName,
    required Uint8List body,
  }) {
    final ReadReceipt r;
    try {
      r = ReadReceipt.decode(body);
    } catch (e) {
      DebugLog.instance.log('RECEIPT', 'drop ${channel.name} receipt: $e');
      return;
    }
    if (r.status != ReceiptStatus.read) return;
    _ref.read(messagesControllerProvider.notifier).applyChannelRead(
          channel.name,
          readerId: readerId,
          readerName: readerName,
          wireIds: r.msgIds.map(TransportEnvelope.hashHex).toSet(),
          at: DateTime.now(),
        );
  }

  /// A reaction from a peer, applied to both the canonical (pubkey-hex) and
  /// any open transport-id bucket for that peer.
  void _ingestPeerReaction({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List? senderEdPub,
    required Uint8List body,
  }) {
    final Reaction rx;
    try {
      rx = Reaction.decode(body);
    } catch (e) {
      DebugLog.instance.log('REACT', 'drop reaction from $peerId: $e');
      return;
    }
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    final reactorId =
        senderEdPub != null ? _hexOf(senderEdPub).substring(0, 16) : 'them';
    final buckets =
        canonical != peerId ? <String>[canonical, peerId] : <String>[canonical];
    _applyReactionToBuckets(buckets, rx: rx, reactorId: reactorId);
  }

  void _applyReactionToBuckets(
    List<String> buckets, {
    required Reaction rx,
    required String reactorId,
  }) {
    final messages = _ref.read(messagesControllerProvider.notifier);
    final target = TransportEnvelope.hashHex(rx.targetMsgId);
    for (final b in buckets) {
      messages.applyReaction(
        b,
        targetWireId: target,
        emoji: rx.emoji,
        reactorId: reactorId,
        add: rx.op == ReactionOp.add,
      );
    }
  }

  /// Resolve the X25519 static pubkey for a peer chat id (pubkey-hex): prefer
  /// a live authenticated session, else the KnownPeers roster.
  Uint8List? _resolvePeerPub(String canonicalId) {
    final session = _findSessionByPubkeyHex(canonicalId);
    if (session != null && session.isEstablished) {
      final p = session.remoteStaticPublicKey;
      if (p != null) return p;
    }
    final known = _ref.read(knownPeersControllerProvider)[canonicalId];
    if (known != null) {
      try {
        return _hexDecodeBytes(known.pubkeyHex);
      } catch (_) {}
    }
    return null;
  }

  /// Best-effort display name for a channel author, matched from the roster by
  /// their Ed25519 signing key. Falls back to a short key fingerprint.
  String _resolveAuthorName(Uint8List edPub) {
    final peer = _knownPeerBySignKey(edPub);
    if (peer != null && peer.displayName.isNotEmpty) return peer.displayName;
    return 'Peer ${_hexOf(edPub).substring(0, 6)}';
  }

  void _notifyChannel({
    required Channel channel,
    required String authorName,
    required Message message,
  }) {
    if (AppLifecycle.instance.isViewingChat(channel.name)) return;
    final nickname =
        _ref.read(nicknameControllerProvider).replaceAll(RegExp(r'\s+'), '_');
    final mentioned = RegExp(
      r'(^|\s)@' + RegExp.escape(nickname) + r'(\s|$)',
      caseSensitive: false,
    ).hasMatch(message.text);
    unawaited(NotificationService.instance.showMessage(
      threadKey: channel.name,
      title: mentioned ? '@ ${channel.name}' : channel.name,
      body: '$authorName: ${message.text}',
      senderId: channel.name,
      isGroup: true,
    ));
  }

  /// Linear scan through active sessions for the one whose authenticated
  /// pubkey matches [pubkeyHex]. Returns null if no live session for that
  /// peer (e.g. the user is browsing chat history while the peer is offline).
  ChatSession? _findSessionByPubkeyHex(String pubkeyHex) {
    final sessions = _ref.read(chatSessionManagerProvider);
    for (final s in sessions.values) {
      if (s.remotePubkeyHex == pubkeyHex) return s;
    }
    return null;
  }

  Future<void> disconnect(String peerId) async {
    final c = _clients.remove(peerId);
    await c?.dispose();
    _ref.read(chatSessionManagerProvider.notifier).drop(peerId);
  }

  // -------------------- inbound dispatch --------------------

  /// Single entry point for bytes arriving on any link. [fromCentral] is true
  /// when the remote is a central writing to our peripheral — it decides which
  /// way a reply goes (notify vs. GATT write), so it must survive reassembly.
  Future<void> _handleInboundBytes(
    String peerId,
    Uint8List bytes, {
    bool fromCentral = false,
  }) async {
    final Frame frame;
    try {
      frame = Frame.decode(bytes);
    } catch (e) {
      DebugLog.instance.log('NOISE', 'drop malformed frame from $peerId: $e');
      return;
    }
    // Link-layer reassembly: a fragment is one slice of a frame that was too
    // big for this link's MTU. Rejoin it before any dispatch/dedup/relay so the
    // rest of the stack never sees fragments. Only when the last slice lands do
    // we recurse with the whole frame.
    if (frame.type == FrameType.fragment) {
      final whole = _fragments.ingest(peerId, frame.payload);
      if (whole != null) {
        await _handleInboundBytes(peerId, whole, fromCentral: fromCentral);
      }
      return;
    }
    await _handleFrame(peerId, frame, fromCentral: fromCentral);
  }

  Future<void> _handleFrame(
    String peerId,
    Frame frame, {
    required bool fromCentral,
  }) async {
    // Transport frames during chunked-media transfer fire dozens-per-second.
    // Logging every one swamps the in-memory ring buffer; we only log
    // handshake + announcement traffic by default. Per-chunk progress is
    // already covered by the reassembler's sampled output.
    if (frame.type != FrameType.transport) {
      DebugLog.instance.log(
          'NOISE',
          'RX ${frame.type.name} from $peerId (${frame.payload.length}B, '
              '${fromCentral ? "peripheral side" : "central side"})');
    }

    final manager = _ref.read(chatSessionManagerProvider.notifier);

    switch (frame.type) {
      case FrameType.noiseHandshake1:
        // Only valid when we're acting as responder (peripheral side received
        // a fresh HS1 from a central we don't yet have a session with).
        //
        // XX hands our static key to whoever asked, which is fine while we are
        // advertising ourselves to strangers and not fine when we are not. With
        // discovery off the only accepted opener is IK, which the caller can
        // only produce if they already hold that key — so an unknown caller
        // gets nothing, not even confirmation that a cubechat identity is here.
        if (!_ref.read(discoverySettingsProvider).discoverable) {
          DebugLog.instance
              .log('NOISE', 'refused XX from $peerId: not discoverable');
          return;
        }
        _armHandshakeWatchdog(peerId);
        final session = await manager.startResponder(peerId);
        final reply = await session.handleHandshakeFrame(frame);
        manager.touch(peerId);
        if (session.isEstablished) {
          _clearHandshakeWatchdog(peerId);
          _registerKnownPeer(session);
        }
        if (reply != null)
          await _writeBack(peerId, reply, fromCentral: fromCentral);

      case FrameType.noiseIk1:
        // Always accepted: producing this required our static key already, so
        // answering it reveals nothing a stranger could not have had.
        _armHandshakeWatchdog(peerId);
        final session = await manager.startResponderIk(peerId);
        final reply = await session.handleHandshakeFrame(frame);
        manager.touch(peerId);
        if (session.isEstablished) {
          _clearHandshakeWatchdog(peerId);
          _registerKnownPeer(session);
        }
        if (reply != null)
          await _writeBack(peerId, reply, fromCentral: fromCentral);

      case FrameType.noiseIk2:
      case FrameType.noiseHandshake2:
      case FrameType.noiseHandshake3:
        final session = manager.sessionFor(peerId);
        if (session == null) {
          debugPrint('drop ${frame.type}: no session for $peerId');
          return;
        }
        final reply = await session.handleHandshakeFrame(frame);
        manager.touch(peerId);
        if (session.isEstablished) {
          _clearHandshakeWatchdog(peerId);
          _registerKnownPeer(session);
        }
        if (reply != null)
          await _writeBack(peerId, reply, fromCentral: fromCentral);

      case FrameType.transport:
        await _handleTransportFrame(peerId, frame);

      case FrameType.peerAnnouncement:
        await _handlePeerAnnouncementFrame(peerId, frame);

      case FrameType.fragment:
        // Fragments are reassembled in _handleInboundBytes before dispatch, so
        // one reaching here means a slice leaked past reassembly — drop it.
        DebugLog.instance
            .log('NOISE', 'unexpected fragment frame at dispatch from $peerId');

      case FrameType.reset:
        manager.drop(peerId);
        _clients.remove(peerId)?.dispose();
    }
  }

  /// Transport-frame dispatch — pulls the envelope apart, decides whether
  /// this frame is for us or for someone else (relay path lands in M3.E),
  /// and decrypts + delivers when addressed.
  Future<void> _handleTransportFrame(String peerId, Frame frame) async {
    final TransportEnvelope env;
    try {
      env = TransportEnvelope.decode(frame.payload);
    } catch (e) {
      DebugLog.instance
          .log('NOISE', 'drop transport from $peerId: malformed envelope ($e)');
      return;
    }
    // Suppressed by default — see _handleFrame above. The reassembler logs
    // sampled progress, and any decode/decrypt/sig failures still produce
    // their own log lines below.

    // Dedup: drop frames we've already seen via another path. Keyed on the
    // (origin, msgId) pair which is stable regardless of which relay
    // delivered the copy.
    if (!_dedup.acceptEnvelope(env)) {
      DebugLog.instance
          .log('NOISE', 'drop transport: duplicate (origin+msgId)');
      return;
    }

    final isForMe = await _isAddressedToMe(env.destPubkeyHash);
    final addressedToMe = env.isBroadcast || isForMe;

    // M3.E forwarding: a frame that isn't ours OR is a broadcast both warrant
    // re-emission on every other link, decremented by one hop. The receiver
    // side dedups on (origin, msgId) so loops collapse on the next iteration.
    if ((!isForMe || env.isBroadcast) && env.ttl > 0) {
      unawaited(_forwardEnvelope(
        outerType: FrameType.transport,
        env: env,
        excludePeerId: peerId,
      ));
    }

    if (!addressedToMe) {
      // Opportunistic store-and-forward: besides the immediate relay above,
      // hold an encrypted copy for the destination so we can hand it over
      // if/when they connect to us directly later (data-mule delivery).
      // Broadcast frames (announcements) don't need holding — they're for
      // everyone and re-broadcast on their own cadence.
      if (!env.isBroadcast) {
        _store.store(
          destHash: env.destPubkeyHash,
          frameBytes: frame.encode(),
          origin: env.originPubkeyHash,
          msgId: env.msgId,
        );
        _scheduleRelayPersist();
        DebugLog.instance.log(
            'MESH',
            'transport not for me — forwarded + held for dest '
                '(${_store.size} frame(s) across ${_store.destinationCount} dest)');
      } else {
        DebugLog.instance
            .log('MESH', 'broadcast not for me, forwarded only (no hold)');
      }
      return;
    }

    // Addressed to us — open the SealedBox body with our long-term private
    // key. Note: SealedBox is anonymous — the sender's identity comes from
    // env.originPubkeyHash and is unauthenticated. For now we cross-check
    // against the immediate-link Noise session's remote pubkey when one
    // exists; multi-hop senders are taken on faith pending inner signatures.
    try {
      final identity = await _ref.read(identityProvider.future);
      if (env.body.isEmpty) {
        DebugLog.instance
            .log('CRYPTO', 'drop transport from $peerId: empty body');
        return;
      }
      // First byte = cipher tag (0x01 SealedBox, 0x02 X3DH forward-secret,
      // 0x03 shared-key channel broadcast).
      final cipher = env.body[0];
      final cipherBody = Uint8List.sublistView(env.body, 1);

      if (cipher == _cipherChannel) {
        await _handleChannelBody(
          env: env,
          peerId: peerId,
          channelBody: cipherBody,
        );
        return;
      }

      final Uint8List sealedPlain;
      if (cipher == _cipherX3dh) {
        final prekeys = _ref.read(prekeyServiceProvider);
        await prekeys.ensureInitialized();
        final FsParsed parsed;
        try {
          parsed = FsMessage.parse(cipherBody);
        } catch (e) {
          DebugLog.instance
              .log('CRYPTO', 'drop FS from $peerId: malformed ($e)');
          return;
        }
        try {
          final sk = await X3dh.deriveReceiver(
            identityKeyPair: identity.asKeyPair(),
            signedPrekeyPair: prekeys.signedPrekeyKeyPair,
            senderIdentityPub: parsed.senderIdentityPub,
            senderEphemeralPub: parsed.senderEphemeralPub,
          );
          sealedPlain = await FsMessage.open(key: sk, parsed: parsed);
          DebugLog.instance
              .log('CRYPTO', 'FS (X3DH) body decrypted from $peerId');
        } catch (e) {
          DebugLog.instance.log('CRYPTO', 'FS decrypt FAILED from $peerId: $e');
          return;
        }
      } else if (cipher == _cipherSealedBox) {
        try {
          sealedPlain = await SealedBox.open(
            cipherBody,
            recipientKeyPair: identity.asKeyPair(),
            recipientPubkey: identity.publicKey,
          );
        } catch (e) {
          DebugLog.instance
              .log('NOISE', 'SealedBox open FAILED for $peerId: $e');
          return;
        }
      } else if (cipher == _cipherX3dhMedia) {
        // Forward-secret media chunk. The per-transfer key rides in the
        // (v0x02) manifest; if that hasn't arrived we hold the encrypted
        // chunk and flush it once the key is derived.
        final Uint8List mediaIdBytes;
        try {
          mediaIdBytes = MediaFsCipher.readMediaId(cipherBody);
        } catch (e) {
          DebugLog.instance.log(
              'CRYPTO', 'drop FS media chunk from $peerId: malformed ($e)');
          return;
        }
        final mediaIdHex = _hexOf(mediaIdBytes);
        final key = _mediaKeys[mediaIdHex];
        if (key == null) {
          _gcMediaBuffers();
          final held = _pendingFsChunks.putIfAbsent(mediaIdHex, () => []);
          if (held.length < _maxPendingFsChunks) {
            held.add(_PendingFsChunk(
              peerId: peerId,
              body: Uint8List.fromList(cipherBody),
              arrivedAt: DateTime.now(),
            ));
          }
          return;
        }
        try {
          sealedPlain = await MediaFsCipher.open(key: key, body: cipherBody);
        } catch (e) {
          DebugLog.instance
              .log('CRYPTO', 'FS media chunk decrypt FAILED from $peerId: $e');
          return;
        }
      } else {
        DebugLog.instance.log(
            'CRYPTO',
            'drop transport from $peerId: unknown cipher tag '
                '0x${cipher.toRadixString(16)}');
        return;
      }

      // Interpret the decrypted plaintext: full signed (0xA1), compact
      // signed (0xA2, FS), or unsigned media chunk.
      final ctx = SignedPayload.contextBytes(
        originPubkeyHash: env.originPubkeyHash,
        destPubkeyHash: env.destPubkeyHash,
        msgId: env.msgId,
      );
      Uint8List innerBytes;
      Uint8List? verifiedSenderEdPub;
      if (sealedPlain.isNotEmpty &&
          sealedPlain[0] == SignedPayload.markerByte) {
        try {
          final expectedEd = await _expectedEdPubFor(env.originPubkeyHash);
          final verified = await SignedPayload.verify(
            wire: sealedPlain,
            context: ctx,
            expectedEdPub: expectedEd,
          );
          if (!_freshEnough(verified.timestampMs, peerId)) return;
          innerBytes = verified.inner;
          verifiedSenderEdPub = verified.senderEdPub;
          DebugLog.instance.log(
              'CRYPTO',
              'signed body verified from $peerId (sender ed pub'
                  '${expectedEd == null ? " — TOFU" : " — strict"})');
        } on SignatureVerificationException catch (e) {
          DebugLog.instance.log('CRYPTO',
              'signed body FAILED verification from $peerId: ${e.message}');
          return;
        }
      } else if (sealedPlain.isNotEmpty &&
          sealedPlain[0] == SignedPayload.markerCompactByte) {
        // Compact (FS) signature carries no embedded ed pub — we must know
        // the sender's verifying key from a prior announcement.
        final expectedEd = await _expectedEdPubFor(env.originPubkeyHash);
        if (expectedEd == null) {
          DebugLog.instance.log(
              'CRYPTO',
              'drop FS body from $peerId: sender ed pub unknown '
                  '(awaiting their announcement)');
          return;
        }
        try {
          final verified = await SignedPayload.verifyCompact(
            wire: sealedPlain,
            context: ctx,
            expectedEdPub: expectedEd,
          );
          if (!_freshEnough(verified.timestampMs, peerId)) return;
          innerBytes = verified.inner;
          verifiedSenderEdPub = expectedEd;
          DebugLog.instance
              .log('CRYPTO', 'compact-signed FS body verified from $peerId');
        } on SignatureVerificationException catch (e) {
          DebugLog.instance.log('CRYPTO',
              'FS body FAILED verification from $peerId: ${e.message}');
          return;
        }
      } else {
        innerBytes = sealedPlain;
      }

      final unpacked = unpackInnerPayload(innerBytes);
      final manager = _ref.read(chatSessionManagerProvider.notifier);
      final session = manager.sessionFor(peerId);
      // Over the Nostr relay there is no Noise session (peerId == _nostrPeerId),
      // so remoteStaticPublicKey is null. Recover the sender's canonical pubkey
      // from the envelope's origin hash so the message routes into their real
      // chat — and so the blocked-peer, receipt, reaction and edit paths below
      // can identify the sender too, instead of it vanishing into 'nostr:relay'.
      final senderPub = session?.remoteStaticPublicKey ??
          await _canonicalPubForOrigin(env.originPubkeyHash);

      final traversedHops = env.traversedHops;
      final directLegacy =
          senderPub != null && session?.remotePubkeyHex == _hexOf(senderPub);
      final incomingRoute = peerId == _nostrPeerId
          ? MessageRoute.internet
          : (traversedHops ?? (directLegacy ? 1 : 2)) > 1
              ? MessageRoute.mesh
              : MessageRoute.bluetooth;
      final incomingHops = peerId == _nostrPeerId ? null : traversedHops;
      // Blocked peer: drop everything they send (messages, receipts,
      // reactions, edits) before it can touch the store or the UI.
      if (senderPub != null &&
          _ref
              .read(knownPeersControllerProvider.notifier)
              .isBlocked(_hexOf(senderPub))) {
        DebugLog.instance.log('MESH', 'drop inbound from blocked peer');
        return;
      }

      // First message from a peer we'd only heard about via an announcement
      // also doubles as a cross-check: cache the verified Ed pub against
      // the origin hash. Future messages will be checked in strict mode.
      if (verifiedSenderEdPub != null) {
        await _maybeCacheSignerForOrigin(
          originHash: env.originPubkeyHash,
          edPub: verifiedSenderEdPub,
        );
      }

      switch (unpacked.type) {
        case InnerPayloadType.text:
          final plaintext = utf8.decode(
            unpadTextPayload(unpacked.body),
            allowMalformed: true,
          );
          DebugLog.instance
              .log('NOISE', 'RX text from $peerId (${plaintext.length} chars)');
          final message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: plaintext,
            sentAt: DateTime.now(),
            isMine: false,
            forwardSecret: cipher == _cipherX3dh,
            wireId: TransportEnvelope.hashHex(env.msgId),
            route: incomingRoute,
            routeHops: incomingHops,
          );
          _appendToAllSessionsForSamePeer(senderPub,
              fallbackPeerId: peerId, message: message);

        case InnerPayloadType.textReply:
          final reply = unpackTextReply(unpacked.body);
          final plaintext = utf8.decode(
            unpadTextPayload(reply.paddedText),
            allowMalformed: true,
          );
          final message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: plaintext,
            sentAt: DateTime.now(),
            isMine: false,
            forwardSecret: cipher == _cipherX3dh,
            wireId: TransportEnvelope.hashHex(env.msgId),
            replyToWireId: TransportEnvelope.hashHex(reply.targetMsgId),
            route: incomingRoute,
            routeHops: incomingHops,
          );
          _appendToAllSessionsForSamePeer(senderPub,
              fallbackPeerId: peerId, message: message);

        case InnerPayloadType.receipt:
          // Symmetric with the send side: someone who withholds their own read
          // receipts does not get to watch other people's.
          if (_ref.read(privacySettingsProvider).shareReadReceipts) {
            _ingestReceipt(
              peerId: peerId,
              senderPub: senderPub,
              body: unpacked.body,
            );
          }

        case InnerPayloadType.reaction:
          _ingestPeerReaction(
            peerId: peerId,
            senderPub: senderPub,
            senderEdPub: verifiedSenderEdPub,
            body: unpacked.body,
          );

        case InnerPayloadType.channelPoll:
          break;

        case InnerPayloadType.channelAdmin:
          break;

        case InnerPayloadType.channelInvite:
          await _ingestChannelInvite(
            peerId: peerId,
            senderEdPub: verifiedSenderEdPub,
            body: unpacked.body,
          );

        case InnerPayloadType.edit:
          _ingestPeerEdit(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.delete:
          _ingestPeerDelete(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.pin:
          _ingestPeerPin(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.presence:
          // Same symmetry as receipts: no beacon out, no online dots in.
          if (_ref.read(privacySettingsProvider).shareLastSeen) {
            _ingestPresence(
              peerId: peerId,
              senderPub: senderPub,
              body: unpacked.body,
            );
          }

        case InnerPayloadType.avatarRequest:
          // Only for a peer we can name: the reply is addressed to a canonical
          // identity, and an unauthenticated frame has none to address.
          if (senderPub != null) {
            await _sendAvatarTo(_hexOf(senderPub));
          }

        case InnerPayloadType.avatar:
          if (senderPub != null) {
            await _ingestAvatar(_hexOf(senderPub), unpacked.body);
          }

        case InnerPayloadType.mediaRequest:
          await _handleMediaRequest(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.fileChunk:
          await _ingestFileChunk(
            peerId: peerId,
            senderPub: senderPub,
            chunkBytes: unpacked.body,
          );

        case InnerPayloadType.imageChunk:
          await _ingestImageChunk(
            peerId: peerId,
            senderPub: senderPub,
            chunkBytes: unpacked.body,
          );

        case InnerPayloadType.audioChunk:
          await _ingestAudioChunk(
            peerId: peerId,
            senderPub: senderPub,
            chunkBytes: unpacked.body,
          );

        case InnerPayloadType.mediaManifest:
          await _ingestMediaManifest(
            peerId: peerId,
            senderPub: senderPub,
            wasSigned: verifiedSenderEdPub != null,
            manifestBytes: unpacked.body,
          );

        case InnerPayloadType.viewOnceConsumed:
          await _ingestViewOnceConsumed(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.conversationClear:
          await _ingestConversationClear(
            peerId: peerId,
            senderPub: senderPub,
          );

        case InnerPayloadType.typing:
          // Symmetric with presence, and with the same switch: withholding
          // your own liveness gives up watching everybody else's.
          if (_ref.read(privacySettingsProvider).shareLastSeen) {
            _ingestTyping(
              peerId: peerId,
              senderPub: senderPub,
              body: unpacked.body,
            );
          }

        case InnerPayloadType.channelAvatar:
        case InnerPayloadType.channelDescription:
          // A room's picture and its topic are broadcasts to its members, and
          // only the channel path knows which room a frame belongs to.
          // Arriving on a 1:1 link they name no channel at all, so there is
          // nothing to apply them to.
          break;
      }
    } catch (e, st) {
      DebugLog.instance.log('NOISE', 'SealedBox open FAILED for $peerId: $e');
      debugPrint('$st');
    }
  }

  /// Drop one audio chunk into the reassembly buffer. Mirrors
  /// [_ingestImageChunk] — completed audio is persisted under
  /// <appCache>/cubechat/audio and surfaced as Message.kind == audio.
  Future<void> _ingestAudioChunk({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List chunkBytes,
  }) async {
    final AudioChunk chunk;
    try {
      chunk = AudioChunk.decode(chunkBytes);
    } catch (e) {
      DebugLog.instance
          .log('VOICE', 'drop audio chunk from $peerId: malformed ($e)');
      return;
    }
    final key = _hexOf(chunk.audioId);
    final pending = _pendingManifests[key];
    if (pending == null) {
      DebugLog.instance.log('VOICE',
          'drop audio chunk from $peerId: no signed manifest for $key');
      return;
    }
    if (pending.manifest.kind != MediaKind.audio ||
        pending.manifest.total != chunk.total ||
        pending.manifest.mime != chunk.mime ||
        pending.manifest.durationMs != chunk.durationMs) {
      DebugLog.instance.log('VOICE',
          'drop audio chunk from $peerId: manifest metadata mismatch for $key');
      return;
    }
    final done = _audioReassembler.ingest(chunk);
    if (done == null) return;
    await _finalizeMedia(
      peerId: peerId,
      senderPub: senderPub,
      kind: MediaKind.audio,
      mediaId: done.audioId,
      bytes: done.bytes,
      mime: done.mime,
      durationMs: done.durationMs,
    );
  }

  /// File a channel photo's manifest so the chunks behind it have something to
  /// be checked against.
  ///
  /// Shares [_pendingManifests] and the image reassembler with the 1:1 path —
  /// both are keyed by the sender's media id, which is unique per transfer
  /// whichever way it travelled. What differs is the destination recorded on
  /// the entry: a room rather than a peer, plus the author, since a broadcast
  /// carries no addressee to look one up by.
  ///
  /// Only images. Voice notes and files in a room are a bigger question — every
  /// member relays every chunk, so a 25 MB attachment is 25 MB across each link
  /// in the mesh — and a manifest claiming another kind is dropped rather than
  /// half-handled.
  Future<void> _ingestChannelManifest({
    required Channel channel,
    required String authorName,
    required String authorId,
    required Uint8List manifestBytes,
  }) async {
    final MediaManifest manifest;
    try {
      manifest = MediaManifest.decode(manifestBytes);
    } catch (e) {
      DebugLog.instance
          .log('CHAN', 'drop ${channel.name} manifest: malformed ($e)');
      return;
    }
    if (manifest.kind != MediaKind.image) {
      DebugLog.instance.log('CHAN',
          'drop ${channel.name} manifest: ${manifest.kind.name} not carried in channels');
      return;
    }
    _gcMediaBuffers();
    _pendingManifests[_hexOf(manifest.mediaId)] = _ManifestEntry(
      manifest: manifest,
      arrivedAt: DateTime.now(),
      peerId: channel.name,
      senderPub: null,
      channel: channel,
      authorName: authorName,
      authorId: authorId,
    );
  }

  /// Drop one image chunk into the reassembly buffer. Once the last chunk
  /// for an imageId lands, the bytes are written to the cache directory
  /// and we append a kind=image Message to the chat.
  Future<void> _ingestImageChunk({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List chunkBytes,
  }) async {
    final ImageChunk chunk;
    try {
      chunk = ImageChunk.decode(chunkBytes);
    } catch (e) {
      DebugLog.instance
          .log('IMG', 'drop image chunk from $peerId: malformed ($e)');
      return;
    }
    final key = _hexOf(chunk.imageId);
    final pending = _pendingManifests[key];
    if (pending == null) {
      DebugLog.instance.log(
          'IMG', 'drop image chunk from $peerId: no signed manifest for $key');
      return;
    }
    // An avatar rides in [ImageChunk] bodies too — the manifest is the only
    // thing that says which of the two this is.
    final kind = pending.manifest.kind;
    if ((kind != MediaKind.image && kind != MediaKind.avatar) ||
        pending.manifest.total != chunk.total ||
        pending.manifest.mime != chunk.mime) {
      DebugLog.instance.log('IMG',
          'drop image chunk from $peerId: manifest metadata mismatch for $key');
      return;
    }
    final done = _imageReassembler.ingest(chunk);
    if (done == null) return;
    await _finalizeMedia(
      peerId: peerId,
      senderPub: senderPub,
      kind: kind,
      mediaId: done.imageId,
      bytes: done.bytes,
      mime: done.mime,
      durationMs: 0,
    );
  }

  /// Same shape as [_ingestImageChunk], but the transfer lands on disk and the
  /// hash is computed by streaming that file back rather than by holding the
  /// whole thing in memory.
  Future<void> _ingestFileChunk({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List chunkBytes,
  }) async {
    final FileChunk chunk;
    try {
      chunk = FileChunk.decode(chunkBytes);
    } catch (e) {
      DebugLog.instance
          .log('FILE', 'drop file chunk from $peerId: malformed ($e)');
      return;
    }
    final key = _hexOf(chunk.fileId);
    final pending = _pendingManifests[key];
    if (pending == null) {
      DebugLog.instance.log(
          'FILE', 'drop file chunk from $peerId: no signed manifest for $key');
      return;
    }
    if (pending.manifest.kind != MediaKind.file ||
        pending.manifest.total != chunk.total) {
      DebugLog.instance.log(
          'FILE', 'drop file chunk from $peerId: manifest mismatch for $key');
      return;
    }

    final files = await _files();
    final done = await files.ingest(chunk);
    if (done == null) {
      final completed = (files.progressOf(chunk.fileId) * chunk.total).round();
      _ref
          .read(fileTransferControllerProvider.notifier)
          .setProgress(key, completed, chunk.total);
      return;
    }

    _gcMediaBuffers();
    final entry = _pendingManifests.remove(key);
    if (entry == null) {
      DebugLog.instance
          .log('FILE', 'drop assembled file $key: manifest expired');
      await done.file.delete().catchError((_) => done.file);
      return;
    }
    await _emitFile(
      peerId: entry.peerId,
      senderPub: entry.senderPub,
      manifest: entry.manifest,
      assembled: done,
    );
  }

  /// Verify the finished file against the manifest's signed commitment and put
  /// it in the chat.
  Future<void> _emitFile({
    required String peerId,
    required Uint8List? senderPub,
    required MediaManifest manifest,
    required AssembledFile assembled,
  }) async {
    try {
      // Hashed by streaming, not by reading the file into a buffer — the whole
      // reason the transfer went to disk was to avoid holding it in memory.
      final sink = Sha256().newHashSink();
      await for (final part in assembled.file.openRead()) {
        sink.add(part);
      }
      sink.close();
      final actual = Uint8List.fromList((await sink.hash()).bytes);
      if (!_bytesEqual(actual, manifest.sha256)) {
        DebugLog.instance.log(
            'FILE',
            'DROP file ${_hexOf(manifest.mediaId)}: sha256 mismatch — '
                'chunks were substituted or reordered under this id');
        await assembled.file.delete();
        return;
      }

      // The name comes from the sender, so it decides nothing about *where*
      // the file goes — only what it is called once it is there.
      final safe = safeFileName(manifest.name ?? 'file');
      final dir = await getApplicationDocumentsDirectory();
      final inbox =
          Directory('${dir.path}${Platform.pathSeparator}cubechat-inbox');
      if (!await inbox.exists()) await inbox.create(recursive: true);
      final target = File('${inbox.path}${Platform.pathSeparator}'
          '${_hexOf(manifest.mediaId).substring(0, 8)}-$safe');
      await assembled.file.rename(target.path);
      _ref.read(fileTransferControllerProvider.notifier).complete(
            _hexOf(manifest.mediaId),
            filePath: target.path,
            bytesTotal: assembled.bytes,
          );

      DebugLog.instance.log(
          'FILE',
          'file ${_hexOf(manifest.mediaId)} sha256 OK '
              '(${assembled.bytes}B, "$safe")');

      _appendToAllSessionsForSamePeer(
        senderPub,
        fallbackPeerId: peerId,
        message: Message(
          id: 'm${DateTime.now().microsecondsSinceEpoch}',
          chatId: peerId,
          text: manifest.mime,
          sentAt: DateTime.now(),
          isMine: false,
          kind: MessageKind.file,
          filePath: target.path,
          fileName: safe,
          fileBytes: assembled.bytes,
          wireId: TransportEnvelope.hashHex(manifest.mediaId),
        ),
      );
    } catch (e, st) {
      DebugLog.instance.log('FILE', 'file persist failed: $e');
      debugPrint('$st');
      try {
        if (await assembled.file.exists()) await assembled.file.delete();
      } catch (_) {/* best effort */}
    }
  }

  /// Whether a manifest for [mediaIdHex] is news, or a second copy of one whose
  /// file is already on this phone.
  ///
  /// A manifest is not delivered once. A relay backlog replays it, the mesh
  /// re-floods it, a store-and-forward buffer hands it over again — and each
  /// arrival used to `register` the incoming task afresh, overwriting the
  /// *completed* one back to `transferring`. The chunks behind it are then
  /// dropped as duplicates by the dedup cache, quite correctly, so nothing ever
  /// completed it a second time: the file was downloaded, opened, perfectly
  /// fine, and its transfer sat in the Active list claiming to be waiting for a
  /// connection forever.
  ///
  /// The file still being on disk is what separates that from the one case
  /// where a repeat manifest is genuinely wanted: a re-request
  /// ([requestMediaAgain]), which is only sent *because* the file is gone.
  Future<bool> _wantsFile(String mediaIdHex) async {
    final transfers = _ref.read(fileTransferControllerProvider.notifier);
    await transfers.loaded;
    final existing = _ref.read(fileTransferControllerProvider)[mediaIdHex];
    if (existing == null ||
        existing.direction != FileTransferDirection.incoming ||
        existing.status != FileTransferStatus.completed) {
      return true;
    }
    if (existing.filePath.isEmpty) return true;
    try {
      if (!await File(existing.filePath).exists()) return true;
    } catch (_) {
      return true;
    }
    DebugLog.instance.log(
        'FILE', 'manifest $mediaIdHex is a repeat — the file is already here');
    return false;
  }

  /// Decode + retain a signed media manifest. Chunks are only accepted after
  /// this signed metadata has arrived, so unsigned orphan chunks cannot fill
  /// reassembly buffers.
  Future<void> _ingestMediaManifest({
    required String peerId,
    required Uint8List? senderPub,
    required bool wasSigned,
    required Uint8List manifestBytes,
  }) async {
    if (!wasSigned) {
      DebugLog.instance.log('CRYPTO',
          'drop media manifest from $peerId: not in a signed wrapper');
      return;
    }
    final MediaManifest manifest;
    try {
      manifest = MediaManifest.decode(manifestBytes);
    } catch (e) {
      DebugLog.instance
          .log('CRYPTO', 'drop media manifest from $peerId: malformed ($e)');
      return;
    }
    final key = _hexOf(manifest.mediaId);
    _gcMediaBuffers();

    // Forward-secret transfer: derive the per-transfer media key so buffered
    // and incoming chunks can decrypt. FS chunks can't be assembled without
    // this, so an FS transfer never lands in the orphan path.
    if (manifest.isForwardSecret) {
      await _deriveAndStoreMediaKey(manifest);
    }

    final orphan = _orphanedMedia.remove(key);
    if (orphan != null) {
      DebugLog.instance
          .log('CRYPTO', 'late manifest matched orphan media $key — verifying');
      await _verifyAndEmit(
        peerId: peerId,
        senderPub: senderPub,
        manifest: manifest,
        bytes: orphan.bytes,
      );
      return;
    }

    if (_pendingManifests.length >= _maxPendingMediaManifests &&
        !_pendingManifests.containsKey(key)) {
      _evictOldestManifest();
    }
    _pendingManifests[key] = _ManifestEntry(
      manifest: manifest,
      arrivedAt: DateTime.now(),
      peerId: peerId,
      senderPub: senderPub,
    );

    if (manifest.kind == MediaKind.file && await _wantsFile(key)) {
      final now = DateTime.now();
      _ref.read(fileTransferControllerProvider.notifier).register(
            FileTransferTask(
              id: key,
              chatId: peerId,
              fileName: manifest.name ?? 'file',
              filePath: '',
              mime: manifest.mime,
              bytesTotal: 0,
              completedUnits: 0,
              totalUnits: manifest.total,
              direction: FileTransferDirection.incoming,
              status: FileTransferStatus.transferring,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    DebugLog.instance.log(
        'CRYPTO',
        'cached signed manifest $key '
            '(${manifest.kind.name} total=${manifest.total}'
            '${manifest.isForwardSecret ? ", FS" : ""})');

    // Now the manifest is registered, drain any FS chunks that raced ahead of
    // it — decrypting them feeds the reassembler, which may complete the media.
    if (manifest.isForwardSecret && _mediaKeys.containsKey(key)) {
      await _flushPendingFsChunks(key);
    }
  }

  /// Derive and cache the inbound X3DH key for a forward-secret media
  /// transfer, from the sender pubs the (v0x02) manifest carries.
  Future<void> _deriveAndStoreMediaKey(MediaManifest manifest) async {
    try {
      final identity = await _ref.read(identityProvider.future);
      final prekeys = _ref.read(prekeyServiceProvider);
      await prekeys.ensureInitialized();
      final sk = await X3dh.deriveReceiver(
        identityKeyPair: identity.asKeyPair(),
        signedPrekeyPair: prekeys.signedPrekeyKeyPair,
        senderIdentityPub: manifest.senderIdentityPub!,
        senderEphemeralPub: manifest.senderEphemeralPub!,
      );
      _mediaKeys[_hexOf(manifest.mediaId)] = sk;
    } catch (e) {
      DebugLog.instance.log('CRYPTO', 'FS media key derive failed: $e');
    }
  }

  /// Decrypt and ingest FS media chunks that arrived before their manifest.
  Future<void> _flushPendingFsChunks(String mediaIdHex) async {
    final key = _mediaKeys[mediaIdHex];
    final held = _pendingFsChunks.remove(mediaIdHex);
    if (key == null || held == null) return;
    final manager = _ref.read(chatSessionManagerProvider.notifier);
    for (final pc in held) {
      Uint8List plain;
      try {
        plain = await MediaFsCipher.open(key: key, body: pc.body);
      } catch (e) {
        DebugLog.instance.log('CRYPTO', 'buffered FS chunk decrypt failed: $e');
        continue;
      }
      final ({InnerPayloadType type, Uint8List body}) unpacked;
      try {
        unpacked = unpackInnerPayload(plain);
      } catch (e) {
        continue;
      }
      final senderPub = manager.sessionFor(pc.peerId)?.remoteStaticPublicKey;
      switch (unpacked.type) {
        case InnerPayloadType.imageChunk:
          await _ingestImageChunk(
            peerId: pc.peerId,
            senderPub: senderPub,
            chunkBytes: unpacked.body,
          );
        case InnerPayloadType.audioChunk:
          await _ingestAudioChunk(
            peerId: pc.peerId,
            senderPub: senderPub,
            chunkBytes: unpacked.body,
          );
        default:
          break; // FS media only carries chunks
      }
    }
  }

  /// Called by [_ingestImageChunk] / [_ingestAudioChunk] once the chunks
  /// for a mediaId have fully reassembled. The signed manifest must still
  /// be present here; otherwise the assembled bytes are dropped.
  Future<void> _finalizeMedia({
    required String peerId,
    required Uint8List? senderPub,
    required MediaKind kind,
    required Uint8List mediaId,
    required Uint8List bytes,
    required String mime,
    required int durationMs,
  }) async {
    final key = _hexOf(mediaId);
    _gcMediaBuffers();
    final pending = _pendingManifests.remove(key);
    if (pending == null) {
      DebugLog.instance
          .log('CRYPTO', 'drop assembled media $key: signed manifest missing');
      return;
    }
    await _verifyAndEmit(
      peerId: pending.peerId,
      senderPub: pending.senderPub,
      manifest: pending.manifest,
      bytes: bytes,
      channel: pending.channel,
      authorName: pending.authorName,
      authorId: pending.authorId,
    );
  }

  Future<void> _verifyAndEmit({
    required String peerId,
    required Uint8List? senderPub,
    required MediaManifest manifest,
    required Uint8List bytes,
    Channel? channel,
    String? authorName,
    String? authorId,
  }) async {
    final digest = await Sha256().hash(bytes);
    final actual = Uint8List.fromList(digest.bytes);
    if (!_bytesEqual(actual, manifest.sha256)) {
      DebugLog.instance.log(
          'CRYPTO',
          'DROP media ${_hexOf(manifest.mediaId)}: '
              'sha256 mismatch (manifest says ${_hexOf(manifest.sha256).substring(0, 8)}…, '
              'assembled ${_hexOf(actual).substring(0, 8)}…)');
      return;
    }
    DebugLog.instance.log(
        'CRYPTO',
        'media ${_hexOf(manifest.mediaId)} sha256 OK '
            '(${bytes.length}B, ${manifest.kind.name})');
    try {
      final Message message;
      switch (manifest.kind) {
        case MediaKind.avatar:
          // Not a message: it is the sender's face, and it still has to match
          // what their signed announcement committed to before it becomes that.
          if (senderPub == null) {
            DebugLog.instance
                .log('AVATAR', 'drop chunked avatar: sender key unknown');
            return;
          }
          await _ingestAvatarBytes(_hexOf(senderPub), bytes);
          return;

        case MediaKind.file:
          // Files never reach here: they complete inside the disk reassembler
          // and go out through [_emitFile], which hashes by streaming instead
          // of materialising the whole transfer as a Uint8List. Reaching this
          // branch would mean a file transfer had been buffered in memory
          // after all, which is the thing that path exists to prevent.
          DebugLog.instance.log('FILE',
              'ignoring in-memory completion for file ${_hexOf(manifest.mediaId)}');
          return;

        case MediaKind.image:
          final path = await ImageReassembler.persistToDisk(
            imageId: manifest.mediaId,
            bytes: bytes,
            mime: manifest.mime,
          );
          message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: manifest.caption ?? manifest.mime,
            sentAt: DateTime.now(),
            isMine: false,
            kind: MessageKind.image,
            imagePath: path,
            imageMime: manifest.mime,
            // The sender's media id, stable across every path and replay that
            // can deliver this photo — the handle that keeps a re-delivered
            // manifest from adding a second copy to the chat.
            wireId: TransportEnvelope.hashHex(manifest.mediaId),
            authorName: authorName,
            authorId: authorId,
            viewOnce: manifest.viewOnce,
          );

        case MediaKind.audio:
          final path = await AudioReassembler.persistToDisk(
            audioId: manifest.mediaId,
            bytes: bytes,
            mime: manifest.mime,
          );
          message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: manifest.mime,
            sentAt: DateTime.now(),
            isMine: false,
            kind: MessageKind.audio,
            audioPath: path,
            audioMime: manifest.mime,
            audioDurationMs: manifest.durationMs,
            wireId: TransportEnvelope.hashHex(manifest.mediaId),
          );
      }
      // A channel photo has no 1:1 session to fan out to and no peer key to
      // canonicalise under — the room name *is* the bucket. It does still want
      // the same banner a channel text message raises.
      if (channel != null) {
        if (_ref
            .read(messagesControllerProvider.notifier)
            .append(channel.name, message)) {
          _notifyChannel(
            channel: channel,
            authorName: authorName ?? '',
            message: message,
          );
        }
        return;
      }
      _appendToAllSessionsForSamePeer(senderPub,
          fallbackPeerId: peerId, message: message);
    } catch (e, st) {
      DebugLog.instance.log('CRYPTO', 'media persist failed: $e');
      debugPrint('$st');
    }
  }

  void _gcMediaBuffers() {
    final cutoff = DateTime.now().subtract(_manifestTtl);
    _pendingManifests.removeWhere((_, e) => e.arrivedAt.isBefore(cutoff));
    _orphanedMedia.removeWhere((_, e) => e.arrivedAt.isBefore(cutoff));
    // Drop FS chunks whose whole buffer went stale (manifest never showed).
    _pendingFsChunks.removeWhere(
        (_, list) => list.every((c) => c.arrivedAt.isBefore(cutoff)));
    // A media key is only useful while its transfer is still in flight (its
    // manifest pending, or chunks buffered). Once neither holds, drop it.
    _mediaKeys.removeWhere((id, _) =>
        !_pendingManifests.containsKey(id) &&
        !_pendingFsChunks.containsKey(id));
  }

  void _evictOldestManifest() {
    String? oldestKey;
    DateTime? oldestAt;
    for (final e in _pendingManifests.entries) {
      if (oldestAt == null || e.value.arrivedAt.isBefore(oldestAt)) {
        oldestAt = e.value.arrivedAt;
        oldestKey = e.key;
      }
    }
    if (oldestKey != null) {
      DebugLog.instance.log('CRYPTO',
          'evict signed media manifest $oldestKey under buffer pressure');
      _pendingManifests.remove(oldestKey);
    }
  }

  /// Build a [MediaManifest] over the about-to-be-sent [bytes], wrap it in
  /// a SignedPayload, SealedBox-encrypt to the peer, and emit one frame.
  /// Throws on missing identity or send failure — caller is expected to
  /// catch and mark the message as failed.
  Future<void> _sendSignedManifest({
    required Uint8List mediaId,
    required MediaKind kind,
    required int total,
    required String mime,
    int durationMs = 0,
    String? name,
    String? caption,
    bool viewOnce = false,

    /// The payload, when it is small enough to have in hand. A file transfer
    /// passes [sha256Digest] instead: the whole point of streaming it off disk
    /// is not to hold twenty-five megabytes in memory just to hash them.
    Uint8List? bytes,
    Uint8List? sha256Digest,
    required Uint8List myHash,
    required Uint8List peerHash,
    required Uint8List peerPub,
    required ChatSession? session,
    required String canonicalId,
    required bool relayOnly,
    Uint8List? senderIdentityPub,
    Uint8List? senderEphemeralPub,
  }) async {
    final identity = await _ref.read(identityProvider.future);
    final sha =
        sha256Digest ?? Uint8List.fromList((await Sha256().hash(bytes!)).bytes);
    final manifest = MediaManifest(
      mediaId: mediaId,
      kind: kind,
      total: total,
      mime: mime,
      durationMs: durationMs,
      name: name,
      caption: caption,
      viewOnce: viewOnce,
      sha256: sha,
      senderIdentityPub: senderIdentityPub,
      senderEphemeralPub: senderEphemeralPub,
    );
    final inner = packInnerPayload(
      InnerPayloadType.mediaManifest,
      manifest.encode(),
    );
    final msgId = TransportEnvelope.newMsgId(initialTtl: _meshTtl);
    final ctx = SignedPayload.contextBytes(
      originPubkeyHash: myHash,
      destPubkeyHash: peerHash,
      msgId: msgId,
    );
    final signed = await SignedPayload.wrap(
      inner: inner,
      context: ctx,
      signKeyPair: identity.asSignKeyPair(),
      senderEdPub: identity.signPublicKey,
    );
    final body =
        _tagBody(_cipherSealedBox, await SealedBox.seal(signed, peerPub));
    final env = TransportEnvelope(
      originPubkeyHash: myHash,
      destPubkeyHash: peerHash,
      msgId: msgId,
      ttl: _meshTtl,
      body: body,
    );
    _dedup.acceptEnvelope(env);
    final frameBytes = Frame(
      type: FrameType.transport,
      payload: env.encode(),
    ).encode();
    // Retried like the chunks behind it. A manifest refused once used to fail
    // the transfer before a single byte of the file had been offered.
    final delivered = await _deliverMediaFrameRetrying(
      frameBytes: frameBytes,
      session: session,
      canonicalId: canonicalId,
      relayOnly: relayOnly,
      gap: Duration.zero,
    );
    if (!delivered.sent) {
      throw const MediaRouteUnavailable();
    }
  }

  /// Verify a signed announcement body and file the peer in the roster.
  ///
  /// Returns false when the bundle was rejected, or when it turned out to be
  /// our own coming back to us — in both cases the caller must not treat it as
  /// news. Signature verification is what stops an attacker on the mesh from
  /// injecting a fake Ed25519 key to break later per-message checks.
  Future<bool> _ingestAnnouncement(Uint8List body, String peerId) async {
    final PeerAnnouncement ann;
    try {
      ann = await PeerAnnouncement.verifyAndDecode(body);
    } catch (e) {
      DebugLog.instance.log(
          'MESH', 'drop announce from $peerId: bad signature / format ($e)');
      return false;
    }
    // Our own, bounced back off a relay or a mesh neighbour. Matched on the
    // announced pubkey rather than the envelope's origin id: the id rotates, so
    // a copy that took a while to return can be wearing a previous epoch's
    // value, while the key inside is what actually says "this is me".
    final identity = await _ref.read(identityProvider.future);
    if (_bytesEqual(ann.pubkey, Uint8List.fromList(identity.publicKey))) {
      DebugLog.instance.log('MESH', 'drop announce: it is mine');
      return false;
    }
    final pubkeyHex = _hexOf(ann.pubkey);
    _ref.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: pubkeyHex,
          displayName: ann.nickname,
          signPublicKey: ann.signPubkey,
          signedPrekeyPub: ann.signedPrekeyPub,
          nostrPubkey: ann.nostrPubkey,
          avatarHash: ann.avatarHash,
          // A v0x05 announcement is authoritative about the picture, including
          // its absence. A v0x04 one has no field for it and must not be read
          // as "they removed it".
          avatarKnown: ann.isAvatarAware,
        );
    unawaited(_reconcileAvatar(pubkeyHex, ann));
    DebugLog.instance.log(
        'MESH',
        'registered SIGNED announce: "${ann.nickname}" ($pubkeyHex) via $peerId '
            '(+ signed prekey + nostr pubkey)');
    return true;
  }

  /// Peers we have already asked for a picture this process, by
  /// `pubkeyHex:hashHex`.
  ///
  /// Keyed by the hash as well as the peer so a *changed* picture is asked for
  /// again while an unchanged one is not: announcements arrive on a heartbeat
  /// and from every mesh neighbour that relays them, and without this each of
  /// those would fire a request for a picture already on its way.
  final Set<String> _avatarRequested = <String>{};

  /// Decide whether this announcement's picture is worth asking for.
  ///
  /// Three cases: they have none (drop whatever we cached — they cleared it),
  /// we already hold the bytes for this digest (nothing to do, the common case
  /// on every heartbeat), or it is new to us (ask once).
  Future<void> _reconcileAvatar(String pubkeyHex, PeerAnnouncement ann) async {
    if (!ann.isAvatarAware) return; // older build, no claim either way
    final avatars = _ref.read(peerAvatarsControllerProvider.notifier);
    await avatars.loaded;

    final hash = ann.avatarHash;
    if (hash == null) {
      await avatars.forget(pubkeyHex);
      return;
    }
    if (await avatars.holds(pubkeyHex, hash)) return;

    final mark = '$pubkeyHex:${_hexOf(hash)}';
    if (!_avatarRequested.add(mark)) return;
    try {
      await _sendAvatarRequest(pubkeyHex);
    } catch (e) {
      // Let a failed ask be retried rather than remembered as done.
      _avatarRequested.remove(mark);
      DebugLog.instance.log('AVATAR', 'request to $pubkeyHex failed: $e');
    }
  }

  Future<void> _sendAvatarRequest(String pubkeyHex) async {
    final peerPub = _resolvePeerPub(pubkeyHex);
    if (peerPub == null) return;
    await _sendControlToPeer(
      canonicalId: pubkeyHex,
      peerPub: peerPub,
      type: InnerPayloadType.avatarRequest,
      innerBody: Uint8List(0),
    );
    DebugLog.instance.log('AVATAR', 'asked ${pubkeyHex.substring(0, 8)}');
  }

  /// Answer someone's [InnerPayloadType.avatarRequest] with our picture.
  /// Silent when we have no picture — the announcement already said so, and a
  /// reply saying it again would only cost airtime.
  ///
  /// A thumbnail small enough to survive fragmentation still goes as one
  /// [AvatarPayload] frame, which is one write and understood by every build.
  /// Anything larger is chunked like a photo — see [MediaKind.avatar].
  Future<void> _sendAvatarTo(String pubkeyHex) async {
    final share = await _ref.read(avatarProvider.notifier).shareable();
    if (share == null) return;
    final peerPub = _resolvePeerPub(pubkeyHex);
    if (peerPub == null) return;
    if (share.jpeg.length > AvatarPayload.maxBytes) {
      await _sendAvatarChunked(pubkeyHex, peerPub, share.jpeg);
      return;
    }
    await _sendControlToPeer(
      canonicalId: pubkeyHex,
      peerPub: peerPub,
      type: InnerPayloadType.avatar,
      innerBody: AvatarPayload(jpeg: share.jpeg).encode(),
    );
    DebugLog.instance.log(
      'AVATAR',
      'sent ${share.jpeg.length}B to ${pubkeyHex.substring(0, 8)}',
    );
  }

  /// Ship a full-size avatar as a signed manifest followed by image chunks.
  ///
  /// Deliberately the *same* machinery a photo uses — [ImageChunk] bodies, the
  /// same reassembler, the same SHA-256 commitment — with only the manifest's
  /// kind saying where the finished bytes belong. Nothing here needed inventing
  /// except somewhere to put the result.
  Future<void> _sendAvatarChunked(
    String pubkeyHex,
    Uint8List peerPub,
    Uint8List jpeg,
  ) async {
    const mime = 'image/jpeg';
    final avatarId = ImageChunk.newImageId();
    final session = _findSessionByPubkeyHex(pubkeyHex);
    final direct = session?.peerId == null ? null : _clients[session!.peerId];
    final relayOnly = !_hasAnyLink;
    final chunkData = _mediaChunkData(direct,
        relayOnly: relayOnly, ceiling: ImageChunk.maxDataBytes);
    final total = (jpeg.length + chunkData - 1) ~/ chunkData;
    if (total < 1 || total > ImageChunk.maxChunks) {
      DebugLog.instance
          .log('AVATAR', 'not sending to $pubkeyHex: $total chunks is too many');
      return;
    }
    final manifest = MediaManifest(
      mediaId: avatarId,
      kind: MediaKind.avatar,
      total: total,
      mime: mime,
      durationMs: 0,
      sha256: Uint8List.fromList((await Sha256().hash(jpeg)).bytes),
    );
    await _sendControlToPeer(
      canonicalId: pubkeyHex,
      peerPub: peerPub,
      type: InnerPayloadType.mediaManifest,
      innerBody: manifest.encode(),
    );
    for (var i = 0; i < total; i++) {
      final start = i * chunkData;
      final end = (start + chunkData).clamp(0, jpeg.length);
      await _sendControlToPeer(
        canonicalId: pubkeyHex,
        peerPub: peerPub,
        type: InnerPayloadType.imageChunk,
        innerBody: ImageChunk(
          imageId: avatarId,
          seq: i,
          total: total,
          mime: mime,
          data: Uint8List.fromList(jpeg.sublist(start, end)),
        ).encode(),
      );
      // Same pacing as every other chunked media path — see [sendImage].
      if (i + 1 < total && !relayOnly) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    }
    DebugLog.instance.log(
      'AVATAR',
      'sent ${jpeg.length}B in $total chunks to ${pubkeyHex.substring(0, 8)}',
    );
  }

  /// Cache a picture someone sent us — but only if it is the one their signed
  /// announcement committed to.
  ///
  /// The bytes and the promise travel separately and by different routes; this
  /// is where they are made to agree. Without the check, anything that could
  /// deliver a frame could choose what a contact's face looks like.
  Future<void> _ingestAvatar(String pubkeyHex, Uint8List body) async {
    final AvatarPayload payload;
    try {
      payload = AvatarPayload.decode(body);
    } catch (e) {
      DebugLog.instance.log('AVATAR', 'drop from $pubkeyHex: $e');
      return;
    }
    await _ingestAvatarBytes(pubkeyHex, payload.jpeg);
  }

  /// The check itself, shared by the one-frame and the chunked arrival.
  Future<void> _ingestAvatarBytes(String pubkeyHex, Uint8List jpeg) async {
    final expected =
        _ref.read(knownPeersControllerProvider)[pubkeyHex]?.avatarHash;
    if (expected == null) {
      DebugLog.instance
          .log('AVATAR', 'drop from $pubkeyHex: nothing announced to match');
      return;
    }
    final avatars = _ref.read(peerAvatarsControllerProvider.notifier);
    await avatars.loaded;
    final ok = await avatars.store(pubkeyHex, jpeg, expected);
    DebugLog.instance.log(
      'AVATAR',
      ok
          ? 'stored ${jpeg.length}B from ${pubkeyHex.substring(0, 8)}'
          : 'drop from $pubkeyHex: does not match the announced digest',
    );
  }

  /// Peer-announcement RX: unwrap envelope, dedup, then either open a sealed
  /// per-recipient introduction or verify a cleartext broadcast, and relay
  /// onward so peers more than one hop away hear it too.
  Future<void> _handlePeerAnnouncementFrame(String peerId, Frame frame) async {
    final TransportEnvelope env;
    try {
      env = TransportEnvelope.decode(frame.payload);
    } catch (e) {
      DebugLog.instance
          .log('MESH', 'drop announce from $peerId: malformed envelope ($e)');
      return;
    }
    if (!_dedup.acceptEnvelope(env)) {
      DebugLog.instance.log('MESH', 'drop announce: duplicate');
      return;
    }
    // An off-mesh introduction is sealed to us (see [_announceOverNostrTo]); a
    // mesh broadcast is the bare signed bundle. The tag byte is unambiguous
    // because a plaintext announcement always opens with version 0x04.
    Uint8List announceBody = env.body;
    if (announceBody.isNotEmpty && announceBody[0] == _announcementSealed) {
      // A sealed introduction is addressed to exactly one recipient, so a node
      // in the middle cannot open it — and must still carry it. Whether we are
      // that recipient is decided by whether the box opens, and *only* by that.
      //
      // It used to be decided by `_isAddressedToMe(env.destPubkeyHash)`, which
      // could never be true: [_announcementFrame] stamps every announcement —
      // sealed ones included — with `broadcastDest()`. So a private
      // introduction always took the forward-and-return branch and was never
      // read, and since a relay introduction rides at ttl 1 the forward then
      // died on the spot. Introductions over Nostr therefore did nothing at
      // all: the peer's own log shows the frame arriving and going straight
      // out again as "ttl exhausted", with no registration between. That is why
      // an avatar digest never landed off-mesh, and why a rename could still
      // fail to arrive even once the sender was pushing it.
      //
      // Trying the open first costs one failed AEAD on a frame that is not ours
      // and keeps the property the dest check was reaching for: what we cannot
      // read, we still carry.
      Uint8List? opened;
      try {
        final identity = await _ref.read(identityProvider.future);
        opened = await SealedBox.open(
          Uint8List.sublistView(announceBody, 1),
          recipientKeyPair: identity.asKeyPair(),
          recipientPubkey: identity.publicKey,
        );
      } on Object {
        opened = null;
      }

      if (opened == null) {
        // Not for us — pass it on blind. Dedup and the hop budget bound this
        // exactly as they do for transport frames.
        if (env.ttl > 0) {
          unawaited(_forwardEnvelope(
            outerType: FrameType.peerAnnouncement,
            env: env,
            excludePeerId: peerId,
          ));
        }
        return;
      }

      // We opened it, so it was addressed to us and stops here.
      await _ingestAnnouncement(opened, peerId);
      return;
    }

    if (!await _ingestAnnouncement(announceBody, peerId)) return;

    // M3.E: announcements are mesh-wide — relay onward on every other link
    // until ttl runs out so peers more than one hop away learn about us.
    if (env.ttl > 0) {
      unawaited(_forwardEnvelope(
        outerType: FrameType.peerAnnouncement,
        env: env,
        excludePeerId: peerId,
      ));
    }
  }

  /// Re-emits [env] (with ttl decremented) wrapped in a [outerType] frame
  /// across every active link except [excludePeerId] (the link we received
  /// it on, to avoid an immediate echo). Per-receiver dedup catches any
  /// loops that escape this filter.
  Future<void> _forwardEnvelope({
    required FrameType outerType,
    required TransportEnvelope env,
    required String? excludePeerId,
  }) async {
    var relayed = env.decrementTtl();
    if (relayed.ttl <= 0) {
      DebugLog.instance
          .log('MESH', 'not forwarding ${outerType.name}: ttl exhausted');
      return;
    }
    // Density cap. This is the point where a flood actually multiplies: we are
    // about to copy one frame onto every link we hold, and each of those peers
    // will do the same. A frame minted in a sparse corner arrives carrying the
    // full budget, and spending all of it once it reaches a crowd is what turns
    // a message into a storm — so the ceiling is re-applied at every hop, using
    // the density of whichever node is doing the forwarding. Only ever lowers
    // the ttl, so a deliberately short hop budget (a relay introduction rides
    // at 1) is never inflated.
    final cap = _meshTtl;
    if (relayed.ttl > cap) {
      relayed = relayed.withTtl(cap);
    }
    final bytes = Frame(type: outerType, payload: relayed.encode()).encode();
    final fanout = await _fanoutAllLinks(bytes, excludePeerId: excludePeerId);
    DebugLog.instance.log(
        'MESH', 'relayed ${outerType.name} ttl=${relayed.ttl} fanout=$fanout');
  }

  /// Writes [bytes] (a fully-encoded frame) onto every active link except
  /// [excludePeerId]. Peripheral notify is always included (it reaches all
  /// subscribed centrals — receiver dedup handles any echo). Returns the
  /// number of links the frame was emitted onto. Each link fragments to its
  /// own MTU, so one oversized frame reaches a mix of high- and low-MTU peers.
  /// Whether any peer could hear a broadcast right now — a connected
  /// central-role client of ours, or a central subscribed to our peripheral.
  /// Mirrors exactly the two paths [_fanoutAllLinks] writes to, so "false"
  /// means a fanout would return 0.
  bool get _hasAnyLink =>
      _clients.values.any((c) => c.isReady) ||
      _ref.read(peripheralControllerProvider).connectedCentralIds.isNotEmpty;

  bool hasMediaRouteFor(String chatId) => _hasMediaRoute(chatId);

  void _startFileQueueTimer() {
    _fileQueueTimer?.cancel();
    _fileQueueTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_drainFileQueue()),
    );
  }

  Future<void> _drainFileQueue() async {
    if (_drainingFileQueue || _disposed) return;
    _drainingFileQueue = true;
    try {
      await _ref.read(fileTransferControllerProvider.notifier).loaded;
      final queued = _ref
          .read(fileTransferControllerProvider)
          .values
          .where(
            (task) =>
                task.direction == FileTransferDirection.outgoing &&
                task.status == FileTransferStatus.queued &&
                _hasMediaRoute(task.chatId),
          )
          .toList();
      for (final task in queued) {
        if (_disposed) break;
        try {
          await retryFileTransfer(task.id);
        } catch (e) {
          DebugLog.instance.log('FILE', 'queued retry failed: $e');
        }
      }
    } finally {
      _drainingFileQueue = false;
    }
  }

  bool _hasMediaRoute(String canonicalId) {
    if (_hasAnyLink) return true;
    if (_relayClient?.isConnected != true) return false;
    final npub =
        _ref.read(knownPeersControllerProvider)[canonicalId]?.nostrPubkey;
    return npub != null && npub.length == 32;
  }

  void _requireMediaRoute(String canonicalId) {
    if (!_hasMediaRoute(canonicalId)) {
      throw const MediaRouteUnavailable();
    }
  }

  /// How many peers could hear us right now — the same two paths
  /// [_fanoutAllLinks] writes to, counted rather than tested. A peer we hold
  /// both a client and a peripheral link to is counted twice; that over-counts
  /// our fan-out slightly, which errs toward the cheaper hop budget and is the
  /// safe direction for a density estimate to be wrong in.
  int get _linkCount =>
      _clients.values.where((c) => c.isReady).length +
      _ref.read(peripheralControllerProvider).connectedCentralIds.length;

  /// Hop budget for anything we put on the mesh, scaled to how dense our
  /// corner of it is. See [TransportEnvelope.ttlForLinkCount].
  int get _meshTtl => TransportEnvelope.ttlForLinkCount(_linkCount);

  /// Data budget for one media chunk. A live direct link sizes to its real MTU;
  /// any other BLE link uses the conservative MTU (both keep one chunk ≈ one
  /// notify, which the peripheral fragmenter + 15 ms pacing rely on to not drop
  /// packets). With **no** BLE link the transfer will go over the Nostr relay as
  /// whole frames — one event each, no fragmentation — so use the full
  /// [ceiling] to keep the relay event count sane (140 B chunks would be
  /// thousands of publishes per image).
  int _mediaChunkData(
    BleGattClient? direct, {
    required bool relayOnly,
    required int ceiling,
  }) {
    if (relayOnly) return ceiling;
    // BLE chunks are sized for the fragmenter, not for one write. See
    // [bleMediaChunkData] for why matching the MTU was the wrong instinct —
    // it spent more airtime on packaging than on the photo.
    final effective = (direct != null && direct.isConnected)
        ? effectivePayload(direct.negotiatedMtu)
        : conservativeEffectivePayload();
    return bleMediaChunkData(effective, ceiling: ceiling);
  }

  /// Carry one media frame (manifest or chunk) to [canonicalId].
  ///
  /// Mirrors the cascade [sendText] uses — direct link, then our peripheral,
  /// then a mesh fan-out, then the Nostr relay — instead of committing to the
  /// session's transport and giving up there. A [ChatSession] outlives the BLE
  /// link that created it, so a peer met earlier still has `session.peerId`
  /// long after the link is gone; the old code took that as "must go over BLE",
  /// failed the notify (no subscribers) and threw `manifest notify rejected`
  /// without ever trying the relay.
  ///
  /// [relayOnly] short-circuits straight to the relay when the transfer was
  /// chunked for it (see [_mediaChunkData]) — a 16 KB chunk sized for one Nostr
  /// event would otherwise be fragmented into ~70 unpaced BLE notifies.
  /// Attempts per chunk before a transfer gives up on it.
  ///
  /// Backed off linearly, so a chunk is worried at for about four seconds
  /// before it counts as lost. That is nothing against a transfer measured in
  /// minutes, and it is the difference between a 2000-chunk file arriving and
  /// one refused event throwing away everything sent so far.
  static const int _mediaChunkAttempts = 5;
  static const Duration _mediaRetryBackoff = Duration(milliseconds: 400);

  /// Deliver one media chunk, riding out a refusal instead of failing the file.
  ///
  /// A public relay answers a burst with `rate-limited: you are noting too
  /// much` and drops the event; a BLE link can be a second into a reconnect.
  /// In both cases the *transfer* is fine and one frame was not — but the first
  /// `false` used to throw [MediaRouteUnavailable], mark the file failed, and
  /// leave the retry to start again from chunk zero, which on a large file
  /// meant it could never finish at all.
  ///
  /// Returns the gap to leave before the next chunk. Zero while the far end is
  /// keeping up; once something has pushed back, it stays non-zero for the rest
  /// of the transfer — a relay that throttled you once will throttle you again,
  /// and pacing into it beats being refused and retrying into it.
  Future<({bool sent, Duration gap})> _deliverMediaFrameRetrying({
    required Uint8List frameBytes,
    required ChatSession? session,
    required String canonicalId,
    required bool relayOnly,
    required Duration gap,
  }) async {
    var next = gap;
    for (var attempt = 1; attempt <= _mediaChunkAttempts; attempt++) {
      if (await _deliverMediaFrame(
        frameBytes: frameBytes,
        session: session,
        canonicalId: canonicalId,
        relayOnly: relayOnly,
      )) {
        return (sent: true, gap: next);
      }
      if (attempt == _mediaChunkAttempts) break;
      // Pushed back on. Slow down for good, and wait longer each time.
      next = next + relayFanoutPacing;
      await Future<void>.delayed(_mediaRetryBackoff * attempt);
    }
    return (sent: false, gap: next);
  }

  Future<bool> _deliverMediaFrame({
    required Uint8List frameBytes,
    required ChatSession? session,
    required String canonicalId,
    required bool relayOnly,
  }) async {
    if (!relayOnly) {
      final transportId = session?.peerId;
      if (transportId != null) {
        final client = _clients[transportId];
        if (client != null && client.isConnected) {
          try {
            await _writeFrameToClient(client, frameBytes);
            return true;
          } catch (e) {
            DebugLog.instance
                .log('MESH', 'media direct write failed ($e) — trying mesh');
          }
        }
        try {
          if (await _notifyFrameToPeripheral(frameBytes)) return true;
        } catch (_) {}
      }
      if (await _fanoutAllLinks(frameBytes, excludePeerId: null) > 0) {
        return true;
      }
    }
    return _sendOverNostr(canonicalId, frameBytes);
  }

  Future<int> _fanoutAllLinks(
    Uint8List bytes, {
    required String? excludePeerId,
  }) async {
    var fanout = 0;
    for (final entry in _clients.entries) {
      if (entry.key == excludePeerId) continue;
      // isReady, not isConnected: a link mid-service-discovery is "connected"
      // but its outbound characteristic isn't there yet, so a write throws
      // "outbound characteristic not ready". Skipping it drops nothing that a
      // write would have delivered — the write would have failed — and avoids
      // the failure + 50 ms retry churn seen when several peers connect at
      // once. A freshly-ready link catches up via the on-handshake announce.
      if (!entry.value.isReady) continue;
      try {
        await _writeFrameToClient(entry.value, bytes);
        fanout++;
      } catch (e) {
        DebugLog.instance.log('MESH', 'fanout client write failed: $e');
      }
    }
    try {
      final ok = await _notifyFrameToPeripheral(bytes);
      if (ok) fanout++;
    } catch (e) {
      DebugLog.instance.log('MESH', 'fanout notify failed: $e');
    }
    return fanout;
  }

  /// Send one whole frame to a directly-connected central-role client,
  /// splitting it into [FrameType.fragment] frames sized to the link's
  /// negotiated MTU when it wouldn't fit a single BLE write. Small frames pass
  /// through untouched. Propagates a write failure to the caller (which decides
  /// whether to queue / mark failed), matching the old direct-write contract.
  Future<bool> _writeFrameToClient(
      BleGattClient client, Uint8List frameBytes) async {
    final parts =
        fragmentFrame(frameBytes, effectivePayload(client.negotiatedMtu));
    for (final part in parts) {
      await client.writeOutbound(part);
    }
    return true;
  }

  /// Notify one whole frame to every subscribed central via our peripheral,
  /// fragmenting to a conservative MTU (the per-central value isn't reported on
  /// the peripheral side). Returns true only if every fragment was accepted.
  /// The native side queues + drains on backpressure, so a full transmit queue
  /// no longer surfaces here as a failure the way it used to.
  Future<bool> _notifyFrameToPeripheral(Uint8List frameBytes) async {
    final peripheral = _ref.read(blePeripheralProvider);
    final parts = fragmentFrame(frameBytes, conservativeEffectivePayload());
    var ok = true;
    for (final part in parts) {
      final accepted = await peripheral.notifyInbound(part);
      if (!accepted) ok = false;
    }
    return ok;
  }

  /// Replay-window gate shared by the full + compact signed paths. The
  /// signed timestamp can't be refreshed by a relay without the sender's
  /// Ed25519 key, so a captured frame re-injected after dedup expiry still
  /// carries its original send time. Returns false (and logs) when the
  /// frame is too old or implausibly far in the future.
  bool _freshEnough(int timestampMs, String peerId) {
    final skewMs = DateTime.now().millisecondsSinceEpoch - timestampMs;
    if (skewMs > _replayMaxAgeMs) {
      DebugLog.instance.log(
          'CRYPTO',
          'drop signed body from $peerId: stale '
              '(${(skewMs / 1000).round()}s old > replay window)');
      return false;
    }
    if (skewMs < -_replayMaxFutureMs) {
      DebugLog.instance.log(
          'CRYPTO',
          'drop signed body from $peerId: timestamp '
              '${(-skewMs / 1000).round()}s in the future (clock skew?)');
      return false;
    }
    return true;
  }

  /// Returns the cached Ed25519 verifying key for the peer wearing
  /// [originPubkeyHash], or null if we've never seen a signed announcement
  /// from them.
  Future<Uint8List?> _expectedEdPubFor(Uint8List originPubkeyHash) async {
    final pub = await _peerForId(originPubkeyHash);
    if (pub == null) return null;
    return _ref.read(knownPeersControllerProvider)[_hexOf(pub)]?.signPublicKey;
  }

  /// Reverse an envelope's [originPubkeyHash] back to the sender's full
  /// canonical (X25519 static) pubkey. Needed on the Nostr path, where there is
  /// no Noise session to read `remoteStaticPublicKey` from — without it an
  /// inbound relay message is filed under the 'nostr:relay' placeholder instead
  /// of the sender's own chat, so it decrypts fine yet never shows up in the
  /// conversation.
  Future<Uint8List?> _canonicalPubForOrigin(Uint8List originPubkeyHash) =>
      _peerForId(originPubkeyHash);

  /// Caches a fresh (origin → ed pub) binding learned from a successful
  /// TOFU-verified message. Bootstraps strict-mode verification for subsequent
  /// messages from the same peer.
  Future<void> _maybeCacheSignerForOrigin({
    required Uint8List originHash,
    required Uint8List edPub,
  }) async {
    final pub = await _peerForId(originHash);
    if (pub == null) return;
    final pubkeyHex = _hexOf(pub);
    final peer = _ref.read(knownPeersControllerProvider)[pubkeyHex];
    if (peer == null || peer.signPublicKey != null) return; // already cached
    _ref.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: pubkeyHex,
          displayName: peer.displayName,
          signPublicKey: edPub,
        );
    DebugLog.instance.log('CRYPTO', 'cached signer for $pubkeyHex via TOFU');
  }

  static Uint8List _hexDecodeBytes(String hex) {
    if (hex.length.isOdd) {
      throw const FormatException('hex string of odd length');
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// Periodic re-announcement of (my pubkey, my nickname) on every active
  /// link. Idempotent: receivers dedup on (origin, msgId), and the roster
  /// upsert is a no-op when nothing changed.
  void _startAnnouncementTimer() {
    _announcementTimer?.cancel();
    _announcementTimer = Timer.periodic(_announcementInterval, (_) {
      unawaited(_broadcastAnnouncement());
    });
  }

  // ------------------------- presence over the internet ---------------------

  /// How often we tell internet-reachable peers we still have the app open.
  /// Two of these fit inside [PeerPresence.ttl], so one dropped beacon doesn't
  /// flicker the dot.
  static const Duration presenceHeartbeat = Duration(seconds: 45);

  /// Most peers one heartbeat will reach. Each beacon is a signed frame
  /// published to every configured relay, so this bounds a pathological roster
  /// (and the relay traffic) to something a phone can afford. The peers that
  /// matter are the ones you've heard from recently, which is how they're
  /// ranked.
  static const int _presenceFanoutCap = 10;

  /// Most peers one channel post is published to. Higher than the presence cap
  /// — missing a room member loses a message, missing a presence beacon only
  /// dims a dot — but still bounded, since every peer here costs one event per
  /// configured relay.
  static const int _channelFanoutCap = 20;

  /// Beacon peers we haven't seen on the mesh in this long: nobody needs an
  /// "online" ping from someone they met once, months ago.
  static const Duration _presenceMaxPeerAge = Duration(days: 30);

  /// Presence heartbeat. Fires regardless of foreground state and checks
  /// inside — [announcePresence] is the one place that decides whether a beacon
  /// is warranted, so there's a single rule to reason about.
  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(presenceHeartbeat, (_) {
      unawaited(announcePresence(online: true));
    });
  }

  /// Tell internet-reachable peers whether we're in the app.
  ///
  /// This exists because the mesh cannot answer the question. A BLE
  /// announcement means "in range"; two people talking from different cities
  /// never are, so before this a peer chatting over the relay always read as
  /// offline. The beacon is deliberately narrow:
  ///
  ///   * **Relay only.** It never touches BLE. A peer in range is already
  ///     covered by announcements, and spending mesh airtime (and battery) on a
  ///     second presence channel is exactly the kind of always-on chatter this
  ///     app has been trimming.
  ///   * **Foreground only** for an "online" beacon. "In the app" is what the
  ///     status claims, so a backgrounded process must not keep claiming it.
  ///   * **Opt-in by construction.** With the internet fallback off there is no
  ///     transport, so nothing is sent. When it is on, the relay learns that
  ///     these two npubs are in contact — which it learns from the first message
  ///     anyway — but on a fixed cadence rather than only when you type.
  Future<void> announcePresence({required bool online}) async {
    if (_disposed) return;
    if (_nostr == null) return;

    // Opted out of last-seen: say "offline", don't fall silent.
    //
    // Silence was the obvious reading and it produced the opposite of what the
    // toggle promises. A peer with no beacon to go on falls back to "did they
    // announce recently" — and announcements are not presence, are not gated by
    // this setting, and over a relay never stop. So turning the toggle on left
    // contacts showing you permanently online, and leaving the app never
    // corrected it because the goodbye was suppressed too.
    //
    // Asserting offline is also the honest meaning of the setting: others see
    // you as not-online, and never learn when you were. It costs nothing extra
    // — the heartbeat that carried "online" now carries "offline" — and because
    // [peerIsOnline] gives a fresh beacon precedence over that fallback, the
    // 45 s heartbeat inside a 150 s TTL keeps the answer pinned.
    final shareLastSeen = _ref.read(privacySettingsProvider).shareLastSeen;
    if (!shareLastSeen) online = false;

    // Checked after the override: a backgrounded process must not claim to be
    // in the app, but it may still say it has left.
    if (online && !AppLifecycle.instance.isForeground) return;

    final now = DateTime.now();

    // Second line of defence behind the lifecycle filter in app.dart. One
    // beacon is N peers × M relays of published events, so a caller that fires
    // it in a tight loop is expensive out of proportion to what it conveys —
    // and the relays answer that with a rate limit that lands on real messages
    // too. Re-stating a status we already published this recently buys nothing:
    // the receiver holds it for a TTL that two heartbeats fit inside.
    final since = _lastPresenceAt;
    if (_presenceInFlight ||
        (_lastPresenceOnline == online &&
            since != null &&
            now.difference(since) < _presenceMinInterval)) {
      return;
    }
    // Claimed before the first await, so a concurrent caller sees it.
    _presenceInFlight = true;
    _lastPresenceOnline = online;
    _lastPresenceAt = now;
    try {
      await _fanOutPresence(online: online, now: now);
    } finally {
      _presenceInFlight = false;
    }
  }

  /// Shortest gap between two beacons saying the same thing. Comfortably below
  /// [presenceHeartbeat] so the heartbeat is never throttled, and far above the
  /// millisecond-scale bursts a lifecycle flap produces.
  static const Duration _presenceMinInterval = Duration(seconds: 20);

  bool? _lastPresenceOnline;
  DateTime? _lastPresenceAt;
  bool _presenceInFlight = false;

  Future<void> _fanOutPresence({
    required bool online,
    required DateTime now,
  }) async {
    // The beacon is relay-only, so with no socket up the whole fan-out is ten
    // peers of guaranteed failure spaced by [relayFanoutPacing] — a second of
    // wakeful work every 45 s on exactly the phone that has no internet.
    if (_relayClient?.isConnected != true) return;
    final peers = _ref
        .read(knownPeersControllerProvider)
        .values
        .where((p) =>
            p.nostrPubkey != null &&
            !p.isBlocked &&
            now.difference(p.lastSeen) < _presenceMaxPeerAge)
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    if (peers.isEmpty) return;

    final body = PresenceBeacon(online: online).encode();
    var sent = 0;
    final targets = peers.take(_presenceFanoutCap).toList();
    for (var i = 0; i < targets.length; i++) {
      final peer = targets[i];
      final Uint8List peerPub;
      try {
        peerPub = _hexDecodeBytes(peer.pubkeyHex);
      } catch (_) {
        continue;
      }
      try {
        final n = await _sendControlToPeer(
          canonicalId: peer.pubkeyHex,
          peerPub: peerPub,
          type: InnerPayloadType.presence,
          innerBody: body,
          relayOnly: true,
        );
        if (n > 0) sent++;
      } catch (e) {
        DebugLog.instance
            .log('PRESENCE', 'beacon to ${peer.pubkeyHex.substring(0, 8)}: $e');
      }
      if (i + 1 < targets.length) {
        await Future<void>.delayed(relayFanoutPacing);
      }
    }
    if (sent > 0) {
      DebugLog.instance.log('PRESENCE',
          'sent ${online ? 'online' : 'offline'} beacon to $sent peer(s)');
    }
  }

  /// A presence beacon from a peer: they have the app open (or are leaving it).
  ///
  /// Also refreshes their roster `lastSeen`, but only for an "online" beacon —
  /// that field is what the chat header falls back to for "offline · 14:05", and
  /// a goodbye must not read as "seen just now" *and* offline at once.
  void _ingestPresence({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final PresenceBeacon beacon;
    try {
      beacon = PresenceBeacon.decode(body);
    } catch (e) {
      DebugLog.instance.log('PRESENCE', 'drop beacon from $peerId: $e');
      return;
    }
    if (senderPub == null) {
      // No canonical identity to attribute it to (an unauthenticated relay
      // frame from someone whose announcement we've never seen).
      DebugLog.instance.log('PRESENCE', 'drop beacon from $peerId: no sender');
      return;
    }
    final canonical = _hexOf(senderPub);
    _ref
        .read(presenceControllerProvider.notifier)
        .record(canonical, online: beacon.online);
    // Both kinds of beacon are evidence of life *now* — a goodbye most of all,
    // since it is the last thing they did before closing the app. Refreshing
    // only on "hello" left the header showing the moment they *arrived*
    // ("offline · 00:57" an hour into a conversation), when what the reader
    // wants is when they left.
    //
    // Safe because [peerIsOnline] gives a fresh beacon precedence over
    // lastSeen: a peer who just said goodbye still reads as offline, now with
    // a timestamp that means "just now" instead of one that means nothing.
    _ref.read(knownPeersControllerProvider.notifier).touch(canonical);
    DebugLog.instance.log('PRESENCE',
        '${canonical.substring(0, 8)} is ${beacon.online ? 'online' : 'offline'}');
  }

  /// Broadcast our announcement immediately, outside the periodic heartbeat.
  ///
  /// For the events that actually change what peers know about us — right now a
  /// rename. Without this, lengthening [_announcementInterval] would mean a new
  /// nickname taking minutes to reach someone we are already talking to; with
  /// it, the change lands at once and the heartbeat stays cheap. No-ops
  /// harmlessly when no link is up.
  Future<void> announceNow() async {
    await _broadcastAnnouncement();
    await _reintroduceOverNostr();
  }

  /// Push a fresh introduction to contacts we can only reach over the internet.
  ///
  /// Two things conspired to make a rename invisible to them.
  /// [_broadcastAnnouncement] returns early unless a Bluetooth link exists —
  /// correct for the heartbeat it was written for, since there is nothing on
  /// the mesh to hear it, but it also skipped the relay. And
  /// [_announceOverNostrTo] introduces us to a given npub once per process, so
  /// even a later relay send would not carry the new name. The peer kept the
  /// old nickname until one side restarted.
  ///
  /// Clearing the marks is what makes the next publish go through. Only ever
  /// on an explicit [announceNow] — a rename or a wipe — never on the
  /// heartbeat, which is how the relay rate-limit was hit before.
  Future<void> _reintroduceOverNostr() async {
    if (_nostr == null) return;
    _announcedOverNostr.clear();

    final peers = _ref
        .read(knownPeersControllerProvider)
        .values
        .where((p) => !p.isBlocked && (p.nostrPubkey?.length ?? 0) == 32)
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    if (peers.isEmpty) return;

    // Bounded, and newest-seen first: one event per contact per relay is
    // affordable for something the user did on purpose, a hundred is not.
    for (final peer in peers.take(_presenceFanoutCap)) {
      try {
        await _announceOverNostrTo(
          _hexOf(peer.nostrPubkey!),
          _hexDecodeBytes(peer.pubkeyHex),
        );
      } catch (e) {
        DebugLog.instance
            .log('NOSTR', 're-introduction to ${peer.pubkeyHex} failed: $e');
      }
    }
  }

  /// Build and send one [PeerAnnouncement] across every active client and the
  /// peripheral notify pipe. Safe to call before any link exists — the
  /// individual sends just no-op.
  Future<void> _broadcastAnnouncement() async {
    // Nothing to announce to, nothing to build. An announcement only ever
    // travels over an established link — a connected GATT client, or a central
    // subscribed to our peripheral — and _fanoutAllLinks is the only path out
    // of here, so with neither present every byte below is discarded.
    //
    // That mattered: this runs on a 60 s timer for the life of the process, and
    // the discarded work includes a prekey-store init and an Ed25519 signature.
    // A phone sitting in a pocket with no peers in range was waking up to sign
    // an announcement for nobody, once a minute, forever.
    if (!_hasAnyLink) return;

    try {
      final signedBody = await buildSignedAnnouncement();
      final originHash = await _myPubkeyHash();

      if (!_ref.read(discoverySettingsProvider).discoverable) {
        await _announcePrivately(
            signedBody: signedBody, originHash: originHash);
        return;
      }

      final frame = _announcementFrame(
        signedBody: signedBody,
        originHash: originHash,
        ttl: _meshTtl,
      );

      final fanout = await _fanoutAllLinks(frame.encode(), excludePeerId: null);
      if (fanout > 0) {
        DebugLog.instance.log('MESH', 'announced on $fanout link(s)');
      }
    } catch (e, st) {
      debugPrint('broadcastAnnouncement failed: $e\n$st');
    }
  }

  /// Announce to the people who already know us, and to nobody else.
  ///
  /// The broadcast announcement is what makes proximity discovery work, and
  /// also what makes a device permanently identifiable: it puts a static
  /// X25519 key and a nickname in the clear, on every link, relayed onward. It
  /// is likewise what would have made rotating routing ids pointless — the ids
  /// are derived from that key, so one overheard announcement lets a listener
  /// recompute every future id.
  ///
  /// With discovery off we send the *same* bundle, but sealed to each contact
  /// individually and addressed to their rotating id. A listener sees one
  /// opaque frame per contact, addressed to identifiers that mean nothing and
  /// change every epoch. Someone we've never met learns nothing and cannot find
  /// us at all — which is the point, and why contact cards exist for the people
  /// we *do* want to reach.
  ///
  /// One honest gap remains: a stranger who connects and completes a Noise XX
  /// handshake still learns our static key, because XX sends it (encrypted to
  /// the peer, hidden from observers, but readable by the initiator). Closing
  /// that needs a different handshake pattern.
  Future<void> _announcePrivately({
    required Uint8List signedBody,
    required Uint8List originHash,
  }) async {
    final peers = _ref
        .read(knownPeersControllerProvider)
        .values
        .where((p) => !p.isBlocked)
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    if (peers.isEmpty) return;

    var sent = 0;
    for (final peer in peers.take(_privateAnnounceCap)) {
      try {
        final peerPub = _hexDecodeBytes(peer.pubkeyHex);
        final env = TransportEnvelope(
          originPubkeyHash: originHash,
          destPubkeyHash: await _peerPubkeyHash(peerPub),
          msgId: TransportEnvelope.newMsgId(initialTtl: _meshTtl),
          ttl: _meshTtl,
          body: _tagBody(
            _announcementSealed,
            await SealedBox.seal(signedBody, peerPub),
          ),
        );
        _dedup.acceptEnvelope(env);
        final frame = Frame(
          type: FrameType.peerAnnouncement,
          payload: env.encode(),
        );
        if (await _fanoutAllLinks(frame.encode(), excludePeerId: null) > 0) {
          sent++;
        }
      } catch (e) {
        DebugLog.instance.log('MESH', 'private announce failed: $e');
      }
    }
    if (sent > 0) {
      DebugLog.instance.log('MESH', 'privately announced to $sent contact(s)');
    }
  }

  /// Ceiling on a private announcement round. Each contact costs its own sealed
  /// frame on every link, where the cleartext broadcast cost one — so a large
  /// roster is bounded, most-recently-seen first.
  static const int _privateAnnounceCap = 24;

  /// Build and Ed25519-sign the current [PeerAnnouncement] for this device —
  /// the identity bundle (X25519 static, Ed25519 verifier, signed prekey, Nostr
  /// pubkey, nickname) every other peer needs to reach us.
  ///
  /// Shared by the three things that hand it out: the mesh broadcast, the
  /// off-mesh introduction ([_announceOverNostrTo]), and the shareable contact
  /// card ([myContactCard]). They differ only in how the bytes travel.
  Future<Uint8List> buildSignedAnnouncement() async {
    final identity = await _ref.read(identityProvider.future);
    final nickname = _ref.read(nicknameControllerProvider);
    final prekeys = _ref.read(prekeyServiceProvider);
    await prekeys.ensureInitialized();
    final nostrSigner = await _myNostrSigner();
    // Only the digest — the picture itself is fetched on request. Cached by the
    // controller, so this costs a map lookup per announcement rather than a
    // JPEG re-encode on a heartbeat.
    final avatarHash = await _ref.read(avatarProvider.notifier).shareableHash();
    final ann = PeerAnnouncement(
      pubkey: Uint8List.fromList(identity.publicKey),
      signPubkey: identity.signPublicKey,
      signedPrekeyPub: prekeys.signedPrekeyPub,
      nostrPubkey: nostrSigner.nostrPubkeyBytes,
      nickname: nickname,
      avatarHash: avatarHash,
    );
    return ann.sign(identity.asSignKeyPair());
  }

  /// Wrap signed announcement bytes in a broadcast envelope + frame, and
  /// pre-record it in the dedup cache so a reflected copy bouncing back from a
  /// relay can't accidentally pass the broadcast self-skip check.
  Frame _announcementFrame({
    required Uint8List signedBody,
    required Uint8List originHash,
    required int ttl,
  }) {
    final env = TransportEnvelope(
      originPubkeyHash: originHash,
      destPubkeyHash: TransportEnvelope.broadcastDest(),
      msgId: TransportEnvelope.newMsgId(initialTtl: _meshTtl),
      ttl: ttl,
      body: signedBody,
    );
    _dedup.acceptEnvelope(env);
    return Frame(type: FrameType.peerAnnouncement, payload: env.encode());
  }

  // ------------------------- contact cards (off-mesh first contact) ---------

  /// This device's shareable contact card — paste it into any other channel to
  /// let someone who has never been in Bluetooth range of you start a chat.
  ///
  /// See [ContactCard] for the format and for what the signature does and does
  /// not prove.
  Future<String> myContactCard() async =>
      ContactCard.encode(await buildSignedAnnouncement());

  /// Import a contact card someone sent us.
  ///
  /// Verifies the signature, refuses our own card, and files the peer in the
  /// roster exactly as a mesh announcement would — so from here on the peer is
  /// indistinguishable from one we met over BLE: they appear in the chats list,
  /// `sendText` can resolve them, and (relay permitting) messages reach them
  /// over the internet.
  ///
  /// Returns the imported peer's canonical pubkey hex. Throws [FormatException]
  /// on a malformed or unsigned-for card, [StateError] on our own card.
  Future<String> addContactFromCard(String raw) async {
    final ann = await ContactCard.parse(raw);
    final identity = await _ref.read(identityProvider.future);
    if (_bytesEqual(ann.pubkey, Uint8List.fromList(identity.publicKey))) {
      throw StateError('that is your own contact card');
    }
    final pubkeyHex = _hexOf(ann.pubkey);
    _ref.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: pubkeyHex,
          displayName: ann.nickname,
          signPublicKey: ann.signPubkey,
          signedPrekeyPub: ann.signedPrekeyPub,
          nostrPubkey: ann.nostrPubkey,
          avatarHash: ann.avatarHash,
          avatarKnown: ann.isAvatarAware,
        );
    // A card is a signed announcement, so it commits to a picture the same way
    // — and someone added from a card is exactly the contact we have never been
    // in radio range of, i.e. the one whose avatar has no other way to arrive.
    unawaited(_reconcileAvatar(pubkeyHex, ann));
    DebugLog.instance.log(
        'MESH',
        'imported contact card: "${ann.nickname}" ($pubkeyHex) '
            '— unverified until fingerprints are compared');

    // Introduce ourselves straight away rather than waiting for the user's
    // first message. The card was one-directional — they handed us their keys
    // and have none of ours — so without this they can see nothing from us and
    // cannot write first.
    await _announceOverNostrTo(_hexOf(ann.nostrPubkey), ann.pubkey);
    return pubkeyHex;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Appends [message] into the canonical pubkey-keyed message bucket, plus
  /// any legacy peerId-keyed buckets that already exist (so a chat opened
  /// before the handshake completed still sees the messages). The chats list
  /// reads from KnownPeersController + the pubkey bucket — the peerId
  /// fan-out is purely for the open-screen case.
  void _appendToAllSessionsForSamePeer(
    Uint8List? pubkey, {
    required String fallbackPeerId,
    required Message message,
  }) {
    final messages = _ref.read(messagesControllerProvider.notifier);
    if (pubkey == null) {
      messages.append(fallbackPeerId, message);
      return;
    }
    final pubkeyHex = _hexOf(pubkey);
    // Canonical key (lives forever, used by chats list). A false return means
    // this exact wireId is already in the chat — a relay backlog replay or a
    // second delivery path — so there is nothing to fan out and nothing to
    // notify about either.
    if (!messages.append(pubkeyHex, message)) {
      // Unless it is the file we asked to have again: same id, same bubble, and
      // the whole point is the new path underneath it.
      final path = message.filePath;
      final wireId = message.wireId;
      if (path != null && wireId != null) {
        if (messages.restoreFilePath(pubkeyHex, wireId, path)) {
          DebugLog.instance
              .log('FILE', 're-sent file $wireId adopted by its bubble');
          return;
        }
      }
      DebugLog.instance.log(
        'NOISE',
        'skip already-stored message ${message.wireId} in $pubkeyHex',
      );
      return;
    }

    // Fan-out to transport-id keys for any currently open ChatScreen that
    // was navigated to via a BLE address.
    final sessions = _ref.read(chatSessionManagerProvider);
    final extras = <String>[];
    for (final entry in sessions.entries) {
      final other = entry.value.remoteStaticPublicKey;
      if (other != null && _pubkeyEquals(other, pubkey)) {
        extras.add(entry.key);
      }
    }
    for (final id in extras) {
      messages.append(id, message);
    }
    DebugLog.instance.log('NOISE',
        'appended to canonical=$pubkeyHex and ${extras.length} transport id(s)');

    _notifyIncoming(canonicalId: pubkeyHex, message: message);
  }

  /// Raise a system notification for an inbound message — but only when the
  /// app isn't in the foreground (otherwise the user is already looking at
  /// it). Sender name comes from the KnownPeers roster; the preview is a
  /// short, content-type-aware snippet.
  void _notifyIncoming(
      {required String canonicalId, required Message message}) {
    if (message.isMine) return;
    // Suppress only when the user is actively reading THIS chat. A message
    // from someone else (or while on the chats list / nearby / backgrounded)
    // still pops a notification.
    if (AppLifecycle.instance.isViewingChat(canonicalId)) return;
    final known = _ref.read(knownPeersControllerProvider)[canonicalId];
    // Muted peer: message is stored, but stays silent.
    if (known?.isMuted ?? false) return;
    final name = (known?.displayName.isNotEmpty ?? false)
        ? known!.displayName
        : 'New message';
    final String preview;
    switch (message.kind) {
      case MessageKind.image:
        preview = '📷 Photo';
      case MessageKind.audio:
        preview = '🎤 Voice message';
      case MessageKind.file:
        preview = '📎 ${message.fileName ?? 'File'}';
      case MessageKind.text:
        preview = message.text;
      case MessageKind.poll:
        preview = '📊 ${message.text}';
    }
    unawaited(NotificationService.instance.showMessage(
      threadKey: canonicalId,
      title: name,
      body: preview,
      senderId: canonicalId,
    ));
  }

  /// Adds (or refreshes) the authenticated peer in the in-memory roster so
  /// the main Chats list shows them even after the BLE session drops.
  void _registerKnownPeer(ChatSession session) {
    final pubkeyHex = session.remotePubkeyHex;
    if (pubkeyHex == null) return;
    _ref.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: pubkeyHex,
          displayName: session.peerLabel,
        );
    DebugLog.instance.log(
        'NOISE', 'registered known peer: ${session.peerLabel} ($pubkeyHex)');
    // Fresh session → kick off an announcement so the new peer (and anyone
    // they relay to) learns who we are without waiting up to a minute for
    // the next periodic tick.
    unawaited(_broadcastAnnouncement());
    // …and hand over anything we've been holding for this peer while they
    // were unreachable (store-and-forward delivery).
    unawaited(_flushStoreForwardFor(session));
  }

  /// Delivers every frame we've been holding for [session]'s peer now that
  /// they're a directly-connected neighbour. Frames go out on the same link
  /// the session lives on, paced like other chunked sends.
  Future<void> _flushStoreForwardFor(ChatSession session) async {
    final pub = session.remoteStaticPublicKey;
    if (pub == null) return;
    final List<Uint8List> hashes;
    try {
      // Every id this peer may have been addressed under while we held their
      // mail — the live epochs plus the pre-rotation fixed hash, since a sender
      // on an older build filed it under that one.
      hashes = [
        ...await PeerId.deriveActive(pub, DateTime.now()),
        await PeerId.legacy(pub),
      ];
    } catch (_) {
      return;
    }
    final pending = _store.drainForAny(hashes);
    if (pending.isEmpty) return;
    _scheduleRelayPersist(); // drain mutated the buffer
    DebugLog.instance.log(
        'MESH',
        'store-and-forward: delivering ${pending.length} held frame(s) '
            'to ${session.peerId}');
    final client = _clients[session.peerId];
    for (final bytes in pending) {
      var sent = false;
      try {
        if (client != null && client.isConnected) {
          await _writeFrameToClient(client, bytes);
          sent = true;
        } else {
          sent = await _notifyFrameToPeripheral(bytes);
        }
      } catch (e) {
        DebugLog.instance.log('MESH',
            'store-and-forward delivery failed for ${session.peerId}: $e');
      }
      // If this was one of our own queued (outbox) messages, flip its
      // chat-bubble status to delivered now that it's actually been handed
      // over to the recipient.
      if (sent) _markOutboxDelivered(bytes);
      // Pace like the chunked-media path so we don't overrun a cheap stack.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Decodes a just-flushed frame to recover its envelope msgId; if it
  /// matches a queued outbox entry, mark that message delivered.
  void _markOutboxDelivered(Uint8List frameBytes) {
    if (_outbox.isEmpty) return;
    try {
      final frame = Frame.decode(frameBytes);
      if (frame.type != FrameType.transport) return;
      final env = TransportEnvelope.decode(frame.payload);
      final key = TransportEnvelope.hashHex(env.msgId);
      final ref = _outbox.remove(key);
      if (ref == null) return;
      final messages = _ref.read(messagesControllerProvider.notifier);
      messages.updateStatus(
          ref.canonicalId, ref.messageId, MessageStatus.delivered);
      if (ref.chatId != ref.canonicalId) {
        messages.updateRoute(
            ref.canonicalId, ref.messageId, MessageRoute.bluetooth,
            hops: 1);
        messages.updateStatus(
            ref.chatId, ref.messageId, MessageStatus.delivered);
      }
      messages.updateRoute(ref.chatId, ref.messageId, MessageRoute.bluetooth,
          hops: 1);
      DebugLog.instance.log(
          'MESH', 'outbox delivered: ${ref.messageId} → ${ref.canonicalId}');
    } catch (_) {
      // not decodable / not ours — ignore
    }
  }

  // -------------------- store-and-forward persistence --------------------

  /// Opens the encrypted relay-buffer box and repopulates [_store] from it.
  /// Stale rows (older than the cache TTL) are dropped during import.
  Future<void> _loadRelayBuffer() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<List<dynamic>>(HiveBoxes.relayBuffer);
      _relayBox = box;
      final raw = box.get('entries');
      if (raw != null && raw.isNotEmpty) {
        final rows = raw
            .whereType<Map<dynamic, dynamic>>()
            .map((m) => m.cast<dynamic, dynamic>())
            .toList();
        _store.importEntries(rows);
        DebugLog.instance.log(
            'MESH',
            'store-and-forward: restored ${_store.size} held frame(s) '
                'across ${_store.destinationCount} dest from disk');
      }
    } catch (e) {
      DebugLog.instance.log('MESH', 'relay buffer load failed: $e');
    }
  }

  /// Debounced write-back of [_store] to disk. Called after any mutation;
  /// coalesces a burst (e.g. relaying a media stream) into one write 2s
  /// after the last change.
  void _scheduleRelayPersist() {
    _relayPersistTimer?.cancel();
    _relayPersistTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_persistRelayBuffer());
    });
  }

  Future<void> _persistRelayBuffer() async {
    final box = _relayBox;
    if (box == null) return;
    try {
      await box.put('entries', _store.exportEntries());
    } catch (e) {
      DebugLog.instance.log('MESH', 'relay buffer persist failed: $e');
    }
  }

  static String _hexOf(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static bool _pubkeyEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _writeBack(
    String peerId,
    Frame frame, {
    required bool fromCentral,
  }) async {
    final bytes = frame.encode();
    DebugLog.instance.log('NOISE',
        'TX ${frame.type.name} (${bytes.length}B) via ${fromCentral ? "peripheral notify" : "central write"}');
    if (fromCentral) {
      // The remote is a central — we're the peripheral, push via notify.
      final ok = await _ref.read(blePeripheralProvider).notifyInbound(bytes);
      if (!ok) {
        DebugLog.instance.log('NOISE',
            'notifyInbound returned false (no subscribers? adapter off? data > MTU?)');
      }
    } else {
      // We are the central — write to peer's outbound characteristic.
      final c = _clients[peerId];
      if (c == null) {
        DebugLog.instance
            .log('NOISE', 'no client for $peerId, cannot write back');
        return;
      }
      await c.writeOutbound(bytes);
    }
  }

  // -------------------- peripheral event hookup --------------------

  /// One line per second of inbound fragments instead of one per fragment. A
  /// single photo is hundreds of writes, and at 200 lines of ring buffer that
  /// was the whole log.
  final _peripheralWriteMeter = TrafficMeter('BLE-PERIPH', 'write from');

  void _wirePeripheralEvents() {
    final peripheral = _ref.read(blePeripheralProvider);
    // SOLE subscriber to peripheral.events() — see comment on PeripheralController
    // about why EventChannel.receiveBroadcastStream() doesn't tolerate multiple
    // Dart listeners. We mirror connected/disconnected changes into
    // PeripheralController via direct method calls.
    _peripheralEventsSub = peripheral.events().listen((event) async {
      if (event is PeripheralLog) {
        DebugLog.instance.log('PERIPH-NATIVE', event.message);
      } else if (event is PeripheralCentralConnected) {
        DebugLog.instance
            .log('BLE-PERIPH', 'central connected: ${event.centralId}');
        _ref
            .read(peripheralControllerProvider.notifier)
            .onCentralConnected(event.centralId);
      } else if (event is PeripheralWrite) {
        _peripheralWriteMeter.add(event.centralId, event.data.length);
        // A central has written to our outbound characteristic — treat it as
        // an inbound frame for the responder side. Goes through
        // _handleInboundBytes (not _handleFrame) so a frame the peer had to
        // fragment for the link MTU is rejoined first; dispatching raw here
        // dropped every fragmented frame we were sent as peripheral.
        await _handleInboundBytes(event.centralId, event.data,
            fromCentral: true);
      } else if (event is PeripheralCentralDisconnected) {
        DebugLog.instance
            .log('BLE-PERIPH', 'central disconnected: ${event.centralId}');
        _ref
            .read(peripheralControllerProvider.notifier)
            .onCentralDisconnected(event.centralId);
        _ref.read(chatSessionManagerProvider.notifier).drop(event.centralId);
      }
    });
  }

  /// True when we're holding any frames waiting for a peer to come back
  /// (store-and-forward buffer or our own queued sends). The discovery layer
  /// uses this to decide whether it's worth auto-connecting to a freshly
  /// seen peer in order to flush.
  bool get hasPendingDelivery => _store.size > 0;

  /// True when we already hold — or are in the middle of opening — a
  /// central-role link to [peerId].
  ///
  /// Mirrors the guard inside [connectAsInitiator] exactly (membership, not
  /// `isConnected`), so a peer whose handshake is still in flight counts as
  /// taken. Callers deciding whether to *start* a connection should ask this
  /// first: reaching connectAsInitiator and being turned away at the door still
  /// costs a scan-result pass and a log line every time.
  bool hasLinkOrPendingTo(String peerId) => _clients.containsKey(peerId);

  /// True while a held frame is recent enough to be worth spending radio on.
  ///
  /// Distinct from [hasPendingDelivery], which stays true for the buffer's full
  /// one-hour TTL. This is the question both radio-spending decisions ask — the
  /// scan cadence and the auto-connect sweep — because "we are still holding
  /// something" is not on its own a reason to keep the radio busy for an hour.
  /// See [BleConstants.pendingDeliveryChase] for the trade.
  ///
  /// Needs no timer of its own — the scanner re-asks at every window boundary
  /// and the sweep at every scan emission, so both relax on their own once the
  /// chase window closes.
  bool get hasFreshPendingDelivery {
    final newest = _store.newestStoredAt;
    if (newest == null) return false;
    return DateTime.now().difference(newest) <
        BleConstants.pendingDeliveryChase;
  }

  /// Drops every frame held in the store-and-forward buffer. Called by
  /// Emergency Wipe — although these frames are opaque (encrypted to other
  /// peers), a panic wipe should leave nothing behind.
  void clearRelayBuffer() {
    _store.clear();
    _outbox.clear();
    _relayPersistTimer?.cancel();
    _relayPersistTimer = null;
    try {
      _relayBox?.delete('entries');
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    _announcementTimer?.cancel();
    _announcementTimer = null;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _fileQueueTimer?.cancel();
    _fileQueueTimer = null;
    // Flush any pending buffer write synchronously so a held frame isn't
    // lost if we're disposed inside the debounce window.
    _relayPersistTimer?.cancel();
    _relayPersistTimer = null;
    await _persistRelayBuffer();
    await _teardownNostr();
    await _peripheralEventsSub?.cancel();
    for (final t in _handshakeTimers.values) {
      t.cancel();
    }
    _handshakeTimers.clear();
    _store.clear();
    for (final c in _clients.values) {
      await c.dispose();
    }
    _clients.clear();
  }
}

final messagingServiceProvider = Provider<MessagingService>((ref) {
  final svc = MessagingService(ref);
  ref.onDispose(() => svc.dispose());
  return svc;
});

/// Tracks a queued outgoing message (held in the store-and-forward buffer
/// because the recipient was offline) so its chat-bubble status can flip to
/// delivered once we actually hand it over.
class _OutboxRef {
  _OutboxRef({
    required this.canonicalId,
    required this.chatId,
    required this.messageId,
  });
  final String canonicalId;
  final String chatId;
  final String messageId;
}

/// One signed media manifest awaiting its chunks. Holds enough context
/// to attribute the resulting Message to the right peer once the bytes
/// have caught up.
class _ManifestEntry {
  _ManifestEntry({
    required this.manifest,
    required this.arrivedAt,
    required this.peerId,
    required this.senderPub,
    this.channel,
    this.authorName,
    this.authorId,
  });
  final MediaManifest manifest;
  final DateTime arrivedAt;

  /// The chat the finished media belongs in: a peer's pubkey hex, or a
  /// `#channel` name when [channel] is set.
  final String peerId;
  final Uint8List? senderPub;

  /// Set when the photo arrived over a channel broadcast rather than a 1:1
  /// link. There is no single sender to attribute it to by key, so the author
  /// travels alongside instead — the same pair every other channel message
  /// carries.
  final Channel? channel;
  final String? authorName;
  final String? authorId;
}

/// Assembled bytes whose manifest hasn't landed yet. We stash the file
/// in-memory only — if no manifest shows up before the GC sweep, the
/// bytes are dropped without ever touching disk (we refuse to surface
/// unauthenticated media in the chat).
class _OrphanMedia {
  _OrphanMedia({
    required this.bytes,
    required this.mime,
    required this.kind,
    required this.durationMs,
    required this.arrivedAt,
    required this.peerId,
    required this.senderPub,
  });
  final Uint8List bytes;
  final String mime;
  final MediaKind kind;
  final int durationMs;
  final DateTime arrivedAt;
  final String peerId;
  final Uint8List? senderPub;
}

/// A forward-secret media chunk (still encrypted) that arrived before its
/// manifest, so before we could derive the transfer key. Held until the
/// manifest lands, then decrypted + ingested by [_flushPendingFsChunks].
class _PendingFsChunk {
  _PendingFsChunk({
    required this.peerId,
    required this.body,
    required this.arrivedAt,
  });
  final String peerId;
  final Uint8List body;
  final DateTime arrivedAt;
}
