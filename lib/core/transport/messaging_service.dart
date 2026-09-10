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
import '../../features/chat/data/conversation_settings_controller.dart';
import '../../features/chat/data/message_farewell.dart';
import '../../features/chat/data/messages_controller.dart';
import '../../features/chat/data/pinned_controller.dart';
import '../../features/chats/data/read_markers_controller.dart';
import '../../features/chat/domain/message_preview.dart';
import '../../features/chat/models/message.dart';
import '../../l10n/app_localizations.dart';
import '../locale/locale_controller.dart';
import '../../features/files/data/file_transfer_controller.dart';
import '../../features/map/data/shared_map_locations_provider.dart';
import '../../features/peers/data/known_peers_controller.dart';
import '../../features/peers/data/removed_contacts_controller.dart';
import '../../features/peers/data/peer_avatars_controller.dart';
import '../../features/peers/data/peer_discovery_controller.dart';
import '../../features/peers/data/peripheral_controller.dart';
import '../../features/peers/data/presence_controller.dart';
import '../../features/peers/data/peer_activity.dart';
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
import 'shared_contact.dart';
import '../notifications/notification_service.dart';
import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
import '../util/app_lifecycle.dart';
import '../util/cost_meter.dart';
import '../util/debug_log.dart';
import '../util/platform_info.dart';
import 'announcement.dart';
import 'ble_gatt_client.dart';
import 'chat_session.dart';
import 'chat_session_manager.dart';
import 'contact_card.dart';
import 'dedup_cache.dart';
import 'shared_location.dart';
import 'store_forward_cache.dart';
import 'envelope.dart';
import 'frame.dart';
import 'frame_fragment.dart';
import 'file_reassembly.dart';
import 'image_reassembly.dart';
import 'mtu_budget.dart';
import 'inner_payload.dart';
import 'channel_poll.dart';
import '../util/media_storage.dart';
import 'channel_admin.dart';
import 'channel_delete.dart';
import 'channel_history.dart';
import 'peer_id.dart';
import 'nostr/nostr_signer.dart';
import 'nostr/nostr_transport.dart';
import 'nostr/relay_watermark_store.dart';
import 'nostr/websocket_relay_client.dart';
import '../crypto/media_fs_cipher.dart';
import '../../features/chat/data/media_send_progress.dart';

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

/// A photo that is already on screen and waiting for its turn on the wire.
///
/// Everything the transfer needs, worked out once when the bubble was minted —
/// except the session, which [MessagingService.transferImage] resolves for
/// itself. By the time a batch reaches its last picture the link may be a
/// different one, or a new one, and the tail of the batch has to use whatever
/// is there rather than what was there when the user pressed send.
class PendingImageSend {
  const PendingImageSend({
    required this.chatId,
    required this.canonicalId,
    required this.peerPub,
    required this.imageId,
    required this.bytes,
    required this.mime,
    required this.caption,
    required this.viewOnce,
    required this.message,
  });

  /// What the caller addressed — a transport id, possibly, rather than the
  /// pubkey.
  final String chatId;

  /// The pubkey-hex bucket the message was actually filed under.
  final String canonicalId;

  final Uint8List peerPub;
  final Uint8List imageId;
  final Uint8List bytes;
  final String mime;
  final String? caption;
  final bool viewOnce;

  /// The bubble, already appended to the store.
  final Message message;
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
    // A room's picture and topic can arrive before the roster knows who is
    // allowed to have sent them; this is what lets the answer catch up, and
    // what tells a new member what the room looks like.
    _ref.listen(
      channelRosterControllerProvider,
      (previous, next) {
        unawaited(_replayHeldChannelState());
        unawaited(_replayHeldChannelPosts());
        _noteNewRoomMembers(previous, next);
      },
    );
    // The 1:1 counterpart. A message signed compactly cannot be checked until
    // its sender's announcement has landed, and the two race; the roster
    // changing is the moment the answer may have arrived, so it is the moment
    // to try what was held. See [_holdUnverified].
    _ref.listen<Map<String, KnownPeer>>(
      knownPeersControllerProvider,
      (previous, next) {
        unawaited(_replayHeldUnverified());
        _greetNewPeers(previous, next);
      },
    );
    _startFileQueueTimer();
    _startStalledMediaTimer();
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

  /// The same bound, across every waiting transfer at once.
  ///
  /// [_maxPendingFsChunks] is per `mediaId`, and a `mediaId` is chosen by the
  /// sender: a fresh one each time steps around the per-transfer cap entirely,
  /// so the only thing bounding this was the manifest TTL. Sixteen mebibytes
  /// of buffered chunks and two dozen simultaneous transfers is far past
  /// anything real — a manifest is sent *before* its chunks, so a transfer
  /// that buffers at all is one that lost a race — and well short of what
  /// makes the OS kill a messenger for its footprint.
  static const int _maxPendingFsBytes = 16 * 1024 * 1024;

  /// How many separate transfers may sit waiting for a manifest at once.
  static const int _maxPendingFsTransfers = 24;

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

  /// Watches an incoming file that has stopped arriving, and asks again.
  ///
  /// **A relay drops the occasional event, and a file needs every one of
  /// them.** Measured on 2026-09-09: a 54-chunk circle went out, and the
  /// receiver's own meter counted 54 frames on the relay — one manifest and
  /// fifty-three chunks. Fifty-four were needed. One event in fifty-five never
  /// turned up, and that was the whole of "circles do not arrive": the bytes
  /// sat on disk, one piece short, for the ten minutes the reassembler waits
  /// before throwing them away, and nothing anywhere said so. Videos went the
  /// same way, for the same reason, because a video is a file too.
  ///
  /// There is no partial re-request on the wire — [requestMediaAgain] asks for
  /// the whole file — so this is deliberately slow to fire and quick to give
  /// up. Better a transfer that costs twice than one that silently never
  /// finishes.
  Timer? _stalledMediaTimer;

  /// Progress last time we looked, per incoming transfer, and how many times
  /// we have asked. Cleared when the transfer completes or the entry goes.
  final Map<String, ({int seen, int asks})> _stalledMedia = {};

  /// How often to look. Well clear of the pacing between chunks, so an
  /// ordinary transfer is never mistaken for a stalled one.
  static const Duration _stallCheck = Duration(seconds: 20);

  /// Asks per transfer before it is left alone. Each one costs the sender the
  /// whole file again, so this is a small number on purpose.
  static const int _maxStallAsks = 2;

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

  /// Album ids from an [AlbumHint] whose photos have not finished arriving,
  /// keyed by the wireId the finished photo will carry.
  ///
  /// The hint is sent first and a batch takes seconds to minutes to transfer,
  /// so in practice this is always populated before there is anything to
  /// apply it to. It is a buffer rather than a lookup because the reverse can
  /// happen — a relay can hand over the photos and the hint in either order —
  /// and [_ingestAlbumHint] stamps whatever already landed as well as leaving
  /// this behind for whatever has not.
  ///
  /// An entry is taken, not read, when its photo finishes — so this empties
  /// itself as a batch lands. The cap is for the rest: a hint whose photos
  /// never arrive is dead weight nothing acknowledges, and insertion order is
  /// what decides which of those goes first.
  final Map<String, String> _pendingAlbums = {};

  /// Enough for several batches in flight at once. Past that the oldest goes,
  /// which costs the grouping on a batch old enough to have been abandoned.
  static const int _maxPendingAlbums = 256;

  /// The shape of a voice note whose audio has not finished arriving.
  ///
  /// Same two-sided arrangement as [_pendingAlbums] and for the same reason:
  /// the levels and the chunks are separate payloads with no ordering between
  /// them. Keyed by the wire id the audio will be filed under, so whichever
  /// lands second finds the first waiting.
  final Map<String, List<int>> _pendingVoiceLevels = {};

  /// Smaller than the album cap: a voice note is one media id, not a batch of
  /// sixty-four, and levels whose audio never arrives are worth even less than
  /// a hint whose photos never arrive.
  static const int _maxPendingVoiceLevels = 64;

  /// Attributions that arrived before the message they belong to.
  final Map<String, _HeldAttribution> _pendingForwardedFrom = {};

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
  StreamSubscription<InboundFrame>? _nostrSub;
  StreamSubscription<Map<String, RelayState>>? _relayStateSub;

  /// Last seen relay connectivity, so [nudgeFileQueue] fires on the edge rather
  /// than on every state message a flapping relay emits.
  bool _relayWasConnected = false;

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
      // And which events those were, not only how far they reached. The REQ
      // asks for ten minutes before the watermark on purpose — see
      // `_sinceSlack` — and everything in that overlap used to be decrypted,
      // reassembled and hashed again on every launch. Measured at 1.43 MB and
      // 61% of one launch's inbound media.
      final seen = await _relayWatermark.loadSeenIds();
      final client = WebSocketNostrRelayClient(
        relayUrls: settings.urls,
        authSigner: signer,
        // Subscribed to like any other — see [RelayLane]. Only *publishing* is
        // split, so a chunk or a beacon never lands somewhere the recipient is
        // not listening.
        mediaRelayUrls: RelaySettings.defaultMediaUrls,
        locationRelayUrls: RelaySettings.defaultLocationUrls,
        sinceSeconds: since,
        onWatermark: (seconds) => unawaited(_relayWatermark.save(seconds)),
        seenIds: seen,
        onSeenIds: (ids) => unawaited(_relayWatermark.saveSeenIds(ids)),
      );
      final transport = NostrTransport(signer: signer, relay: client);
      _relayClient = client;
      _nostr = transport;
      _nostrSub = transport.inboundFramesTimed().listen(
            // Timed as one block, on purpose. Everything a frame off the relay
            // costs is inside here — opening the X3DH or SealedBox body,
            // verifying the payload signature, and whatever the payload then
            // does — and all of it is Dart on the UI isolate. Splitting it
            // finer can come later; what is wanted first is whether this or
            // `nostr-verify` is where the seconds go.
            (frame) => unawaited(CostMeter.instance.measure(
              'relay-frame',
              () => _handleInboundBytes(
                _nostrPeerId,
                frame.bytes,
                // When they said it, not when it reached us. A relay holds
                // events for whoever subscribes next — see [InboundFrame].
                sentAt: frame.sentAt,
              ),
            )),
            onError: (Object e) =>
                DebugLog.instance.log('NOSTR', 'inbound stream error: $e'),
          );
      _relayStateSub = client.stateChanges.listen((states) {
        // A socket state can land after the service is gone: the relay pool
        // lives on its own timers, and disposal cannot un-schedule a callback
        // already on the queue. Reading a provider from a disposed container
        // throws, and this is the one listener that does so on every state
        // message. It surfaced the moment the fallback started on by default
        // and tests began standing a real pool up — a shutdown race that was
        // simply unreachable while the default was off.
        if (_disposed) return;
        _ref.read(relayStatusProvider.notifier).publish(states);
        // A relay coming up is a media route appearing, exactly like a BLE
        // session doing so — and for a peer we only ever reach over the
        // internet it is the *only* one. Nudge on the transition rather than on
        // every state message, or a flapping relay would re-arm the drain
        // continuously and undo the back-off it exists to allow.
        final connected = client.isConnected;
        if (connected && !_relayWasConnected) {
          nudgeFileQueue();
          // And the read receipts that had nowhere to go.
          //
          // A receipt is composed when a chat is opened, and a fan-out of zero
          // is an ordinary return — so one composed while the relay was down is
          // simply not sent, and nothing tries again until that chat is opened
          // a second time. On iOS the relay was *always* down for the first
          // moments after resume (see wakeRelays), which is exactly when
          // somebody opens the app to read what arrived: the messages were
          // read, the other phone's tick never moved, and only re-entering the
          // conversation later fixed it.
          unawaited(_flushPendingReadReceipts());
          // And the messages themselves, which had no such second chance.
          unawaited(_flushOutboxOverRelay());
          // Somebody who was unreachable when the switch moved.
          //
          // Only when it is off: "you may link back to me" is what every build
          // assumes anyway, so re-announcing it would be a fan-out to every
          // contact to tell them nothing. The withheld answer is the one worth
          // catching up, and it is the one that stops working if it does not
          // arrive.
          if (!_ref.read(privacySettingsProvider).allowForwardLink) {
            unawaited(broadcastForwardPrivacy(allowed: false));
          }
        }
        _relayWasConnected = connected;
      });
      client.start();
      _ref.read(relayStatusProvider.notifier).publish(client.states);
      DebugLog.instance.log(
          'NOSTR',
          'internet fallback on — ${settings.urls.length} relay(s) '
              '+ ${RelaySettings.defaultMediaUrls.length} media '
              '+ ${RelaySettings.defaultLocationUrls.length} location, '
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
  /// [wakesPeer] rings the recipient's doorbell — see [kWakeTag]. Off unless
  /// asked, because the doorbell used to ring for everything: the presence
  /// heartbeat alone put a "New message" banner on a closed phone every 70
  /// seconds with nothing behind it.
  Future<bool> _sendOverNostr(
    String canonicalId,
    Uint8List frameBytes, {
    bool wakesPeer = false,
    RelayLane lane = RelayLane.conversation,
  }) async {
    final transport = _nostr;
    // Said out loud, because the silence here is what made a phone look broken:
    // messages queued for hours with no line in the log to say the internet
    // fallback was simply switched off on that device.
    if (transport == null) {
      DebugLog.instance.log(
          'NOSTR', 'internet fallback is off — $canonicalId stays queued');
      return false;
    }
    // If the relay pool is merely asleep/backing off, wake it and wait briefly
    // for one socket. This is the common iOS path: the user opens the app or a
    // background window starts, immediately sends/flushes something, and the
    // relay is still in `connecting`. Returning false in that window pushed a
    // perfectly sendable message into the slow mesh/store-forward path.
    if (!await _ensureRelayAwakeForSend()) return false;
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
        wakesPeer: wakesPeer,
        lane: lane,
      );
      // A write is not a send. Relays refuse events routinely — rate limits,
      // size caps, spam heuristics — and counting a refusal as delivery is how
      // a message disappears while the chat shows it delivered.
      if (receipt.isRefused) {
        DebugLog.instance.log(
            'NOSTR',
            'every relay refused the frame for $canonicalId '
                '(${receipt.rejections.join('; ')})');
        return false;
      }
      // Nor is silence from *everybody*.
      //
      // This used to read "a relay that simply went quiet is treated as
      // acceptance: the event has most likely been stored, and falling back to
      // store-and-forward for silence would strand messages behind one slow
      // relay". The second half is right and the first half is too generous,
      // because the two cases were not separated. One relay quiet while
      // another said yes is exactly the straggler that argument is about, and
      // it still counts as delivered — the publish settles on the first `OK`
      // and does not wait for the rest.
      //
      // Every relay quiet is a different fact. Nobody said yes inside the
      // two-second deadline, and a shipped log has it 16 times in 150
      // publishes, alongside `relay.primal.net down (Connection closed before
      // full header)` — which is the "смс не доходят" report, arriving as a
      // message the chat showed as sent.
      //
      // Held rather than assumed, and the asymmetry is the whole argument: a
      // frame published twice is dropped by the recipient's dedup on msgId, so
      // a wrong guess here costs one duplicate write. A frame assumed
      // delivered and never sent again is gone.
      if (!receipt.isAccepted) {
        DebugLog.instance.log(
            'NOSTR',
            'no relay confirmed the frame for $canonicalId — holding it '
                '($receipt)');
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
        // Dispose, don't merely drop the reference — the same reasoning as the
        // failed-connect path above, for the case that happens far more often.
        // A peer walking out of range is the ordinary end of a BLE link, and
        // this arm ran on every one of them: the client keeps three live
        // subscriptions to the platform's device streams plus two stream
        // controllers, and a bare remove() leaves all five behind. A day of
        // walking past people therefore accumulated one leak per encounter,
        // silently, on the path least likely to be noticed because nothing
        // about it looks like an error.
        unawaited(_clients.remove(peerId)?.dispose() ?? Future<void>.value());
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
  ///  * both phones connect to each other in the same instant — which is the
  ///    normal case when two people open the same chat — and the platform
  ///    hands one of the two clients an empty service list. That reads as "not
  ///    a cubechat device" and is nothing of the sort; see [BleDiscoveryFailed]
  ///    and the `on StateError` arm below, which is where a single field report
  ///    of "connected on the fifth try" was actually coming from.
  ///
  /// A peer that connects, enumerates, and genuinely does not expose the
  /// cubechat service is a permanent failure and is never retried.
  ///
  /// Four attempts rather than three, and each wait a little longer than the
  /// last: the collision above resolves as soon as one side's link settles, and
  /// the extra attempt costs nothing when there is nobody there — that case
  /// fails on the connect itself, in milliseconds.
  Future<void> connectAsInitiatorWithRetry({
    required String deviceId,
    required String displayName,
    Future<String?> Function()? refreshId,
    int attempts = 4,
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
        // Answered, enumerated, and genuinely is not one of ours. Retrying a
        // stranger's phone achieves nothing.
        //
        // Note what this deliberately no longer catches: an *empty* service
        // list, which used to arrive here as the same StateError and was
        // therefore given up on at once. That is a race in the platform, not a
        // verdict about the peer — see [BleDiscoveryFailed] — and it now falls
        // through to the retry below, which is where a person was standing in
        // for the code and pressing the button five times.
        rethrow;
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
  ///
  /// [transient] sends the same encrypted frame but keeps none of it: no
  /// bubble, no history, no delivery status, and no store-and-forward. It
  /// exists for the map's presence beacon, which is a position valid for two
  /// minutes emitted every forty-five seconds — worth transmitting, never worth
  /// remembering, and actively harmful to queue, since a beacon handed over on
  /// a reconnect half an hour later is a lie about where somebody is.
  Future<Message> sendText(
    String chatId,
    String text, {
    String? replyToWireId,

    /// What the quoted message said, captured when the reply was composed.
    ///
    /// Stored on our own copy so the quote box never has to find the original
    /// again — see [Message.replyPreview]. Nothing carries it over the wire;
    /// the far side still resolves the quote by id.
    String? replyPreview,
    bool transient = false,
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
      replyPreview: replyTarget != null ? replyPreview : null,
    );
    // Whether a transient send actually left the phone.
    //
    // A filed message records its own fate — the store gets `delivered` or
    // `queued` and the tick in the bubble follows it. A transient one is filed
    // nowhere, so its fate had no way out of this method: the caller awaited,
    // nothing threw, and "no route" was a line in the log and nothing else.
    //
    // [MapPresenceController] is that caller, and it counts successful sends to
    // decide whether anyone is still receiving — which is what parks the GPS
    // when nobody is. Counting "did not throw" meant it parked never, and the
    // whole mechanism for not holding a location fix open for an audience of
    // nobody has been dead code since it was written. Location is the most
    // expensive thing this app can leave running.
    var transientDelivered = false;
    final messages = _ref.read(messagesControllerProvider.notifier);
    if (!transient) {
      messages.append(canonicalId, msg);
      // Also append under the transport id if the caller passed one (so an
      // open ChatScreen routed via /chat/<bleId> sees the outgoing message
      // until we migrate it to the pubkey-keyed route).
      if (chatId != canonicalId) {
        messages.append(chatId, msg);
      }
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
          if (!transient) {
            messages.markForwardSecret(canonicalId, msg.id);
            if (chatId != canonicalId) {
              messages.markForwardSecret(chatId, msg.id);
            }
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

      // The internet first, if this conversation asked for it.
      //
      // A bias rather than a lock: the road is still whatever is reachable at
      // this instant, and a preference that cannot be honoured is simply not
      // honoured — the radios below are tried exactly as before and the
      // message still goes. What changes is only the order.
      //
      // Bluetooth first stays the default. It is faster in the room, costs no
      // data, and tells a relay nothing; somebody on a poor link and good wifi
      // wants the opposite, and only they can know that.
      if (!transient &&
          _ref
              .read(conversationSettingsControllerProvider.notifier)
              .prefersRelay(canonicalId) &&
          await _sendOverNostr(canonicalId, wireBytes, wakesPeer: true)) {
        deliveredVia = 1;
        deliveredRoute = MessageRoute.internet;
      }
      // Every delivery attempt is wrapped so a transient BLE failure (stale
      // link, peer's Bluetooth turned off, write rejected) leaves
      // deliveredVia == 0 and routes the message into the pending outbox —
      // it must NOT throw to the outer catch and mark the message failed.
      if (deliveredVia == 0 && transportId != null) {
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
      } else if (deliveredVia == 0) {
        deliveredVia = await _fanoutAllLinks(wireBytes, excludePeerId: null);
        if (deliveredVia > 0) deliveredRoute = MessageRoute.mesh;
      }

      // Mesh couldn't carry it → try the internet fallback before queueing.
      // The frame published to a relay is byte-identical to the one BLE would
      // have carried: still SealedBox/X3DH-encrypted and signed, so the relay
      // is a dumb pipe that learns only who talks to whom, and when.
      // `!transient`, and leaving that off is what kept the doorbell ringing
      // after the outbox was fixed. A map pin is a text message — the position
      // rides as a `cubechat:loc:v1:` URI, which is how every small payload
      // travels here — so it comes down this path like anything typed, and
      // `MapPresenceController` republishes it to every map friend on a timer.
      // The server log read as a metronome about every ninety seconds, and the
      // sender's log showed why: four `sendText` calls of the same 287 bytes
      // inside 400 ms, one per friend, right after `[MAP] rebuilding the map`.
      //
      // `transient` already exists to mean "not a message a person wrote" —
      // the branch above consults it — and this one simply did not ask.
      if (deliveredVia == 0 &&
          await _sendOverNostr(
            canonicalId,
            wireBytes,
            wakesPeer: !transient,
            // `transient` is the map beacon and nothing else — the only two
            // callers that set it are `MapPresenceController`'s publish and
            // its retraction. So it is also the answer to which lane this
            // belongs on, with no second flag to keep in step.
            //
            // Worth the split more than media is: a 72-minute field log had
            // 191 of 274 publishes be these, 70% of everything the radio did,
            // to carry 55 kB. That is the throttle a sentence was competing
            // with.
            lane: transient ? RelayLane.location : RelayLane.conversation,
          )) {
        deliveredVia = 1;
        deliveredRoute = MessageRoute.internet;
      }

      // A beacon that went nowhere is simply skipped: it says where somebody is
      // *now*, and the next one is forty-five seconds away.
      if (transient) {
        transientDelivered = deliveredVia > 0;
        if (deliveredVia == 0) {
          DebugLog.instance
              .log('MAP', 'presence beacon to $canonicalId found no route');
        }
      } else if (deliveredVia > 0) {
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
          frameBytes: wireBytes,
        );
        _scheduleRelayPersist();
        DebugLog.instance.log(
            'MESH',
            'text undeliverable — queued for store-and-forward to '
                '$canonicalId (held ${_store.size})');
        // And ask the relays to come back, which is the whole reason this
        // message has nowhere to go on a phone with no peers nearby.
        //
        // The file path already does this a few hundred lines up; text did
        // not, so a message typed on a weak connection — where the socket is
        // still opening, or the backoff has grown to two minutes after a dead
        // spot — was filed away without anything trying to open the road it
        // was waiting for. On EDGE that is the normal case rather than an
        // edge one: the frame is 200-odd bytes, but the TLS and WebSocket
        // handshake in front of it takes longer than a person waits before
        // pressing send.
        wakeRelays();
        // Leave status as sending (pending), not failed.
      }
    } catch (e, st) {
      DebugLog.instance.log('NOISE', 'sendText FAILED: $e');
      debugPrint('sendText failed: $e\n$st');
      if (!transient) {
        messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
        if (chatId != canonicalId) {
          messages.updateStatus(chatId, msg.id, MessageStatus.failed);
        }
      }
    }
    // The transient caller reads its fate off the route, since nothing filed it
    // anywhere it could be read from. `queued` is the same word the store uses
    // for a message that found no road, and it means the same thing here.
    if (transient) {
      return msg.copyWith(
        route: transientDelivered ? MessageRoute.mesh : MessageRoute.queued,
      );
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
  /// At 63 KiB a chunk (see [kRelayMediaChunkData] for where that came from)
  /// 64 MiB is 1040 publishes per relay — minutes of transfer you can watch and
  /// pause, and comfortably inside [FileChunk.maxChunks]. It was 2048 while a
  /// chunk was 32 KiB; the same file now costs half the events, which is the
  /// whole point of the bigger chunk.
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
      wakeRelays();
      nudgeFileQueue();
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
      // One line per transfer, not per chunk — the log holds 200 lines and a
      // single photo batch can fill it. This is the line that answers "why was
      // that slow": over the relay every chunk is a publish and a round trip,
      // so the count *is* the time, and the count is the only thing here that
      // a size change moves.
      DebugLog.instance.log(
        'FILE',
        'sending "$safe" — $size B as $total × $chunkData B '
            '(${relayOnly ? 'relay' : 'mesh'})',
      );

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
    final pending = prepareImage(
      chatId,
      bytes: bytes,
      mime: mime,
      cachedPath: cachedPath,
      caption: caption,
      viewOnce: viewOnce,
    );
    await transferImage(pending);
    return pending.message;
  }

  /// Mint an outgoing photo and put it on screen, without sending anything yet.
  ///
  /// The split exists for batches. [sendImage] does not return until the last
  /// chunk of the picture has crossed the mesh, and the bubble is created at the
  /// top of it — so sending five photos in a loop created the second bubble only
  /// once the first photo had entirely arrived. Over Bluetooth that is minutes,
  /// and what the sender saw was their pictures trickling out one at a time
  /// rather than the batch they picked.
  ///
  /// Preparing them all first puts the whole set on screen at once — which is
  /// also what makes them fold into one album — and the transfers then run one
  /// after another behind them, unchanged and still serialised. Nothing about
  /// the wire is different; only when the user is told.
  ///
  /// Throws before creating anything when there is no route or no recipient, so
  /// a hopeless batch fails as a batch instead of leaving five bubbles behind.
  PendingImageSend prepareImage(
    String chatId, {
    required Uint8List bytes,
    required String mime,
    String? cachedPath,
    String? caption,
    bool viewOnce = false,
    String? albumId,
  }) {
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
      albumId: albumId,
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);
    if (chatId != canonicalId) {
      messages.append(chatId, msg);
    }

    return PendingImageSend(
      chatId: chatId,
      canonicalId: canonicalId,
      peerPub: peerPub,
      imageId: imageId,
      bytes: bytes,
      mime: mime,
      caption: caption0,
      viewOnce: viewOnce,
      message: msg,
    );
  }

  /// Put a photo prepared by [prepareImage] on the wire.
  ///
  /// The session is resolved **here**, not at prepare time. In a batch the last
  /// picture's turn comes minutes after it was minted, and a link that dropped
  /// or came back in between has to be the one that is used — holding the
  /// session captured at prepare would send the tail of a batch down a route
  /// that no longer exists.
  Future<void> transferImage(PendingImageSend pending) async {
    final chatId = pending.chatId;
    final canonicalId = pending.canonicalId;
    final peerPub = pending.peerPub;
    final imageId = pending.imageId;
    final bytes = pending.bytes;
    final mime = pending.mime;
    final caption0 = pending.caption;
    final viewOnce = pending.viewOnce;
    final msg = pending.message;

    final manager = _ref.read(chatSessionManagerProvider.notifier);
    ChatSession? session = manager.sessionFor(chatId);
    session ??= _findSessionByPubkeyHex(chatId);

    final messages = _ref.read(messagesControllerProvider.notifier);

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
        // One number for the ring on the bubble. Quantised inside the
        // controller, so calling it on every chunk of a 300-chunk BLE transfer
        // still only writes state a hundred times.
        _ref
            .read(mediaSendProgressProvider.notifier)
            .report(msg.id, sent: i + 1, total: total);
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
      _ref.read(mediaSendProgressProvider.notifier).clear(msg.id);
      messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
      }
    } catch (e, st) {
      debugPrint('sendImage failed: $e\n$st');
      _ref.read(mediaSendProgressProvider.notifier).clear(msg.id);
      messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.failed);
      }
      // Surface it: the caller shows a snackbar. Silently swallowing left the
      // user with a broken bubble and no idea the link had dropped.
      rethrow;
    }
  }

  /// Send a set of photos as one batch.
  ///
  /// Every bubble appears first, then the pictures go one after another. That
  /// order is the whole point — see [prepareImage] — and it is also what makes
  /// them fold into a single album rather than arriving as separate bubbles
  /// minutes apart.
  ///
  /// The caption belongs to the *set*, so it rides on the first picture, which
  /// is where the album draws it.
  ///
  /// A failure part-way stops the batch: the pictures already sent stay sent,
  /// the rest are marked failed rather than being retried down a route that has
  /// just proved itself dead. The error reaches the caller, which is what puts
  /// the reason on screen.
  Future<void> sendImageBatch(
    String chatId, {
    required List<Uint8List> images,
    required String mime,
    List<String?> cachedPaths = const [],
    String? caption,
    bool viewOnce = false,
  }) async {
    if (images.isEmpty) return;
    // One id across the whole batch, minted here because this is the only
    // moment anything knows where the batch begins and ends. Grouping used to
    // re-derive that from timestamps afterwards, and two batches a minute apart
    // are indistinguishable from one long one that way — see [Message.albumId].
    final albumId = images.length > 1
        ? 'a${DateTime.now().microsecondsSinceEpoch}'
        : null;
    final pending = <PendingImageSend>[];
    for (var i = 0; i < images.length; i++) {
      pending.add(prepareImage(
        chatId,
        bytes: images[i],
        mime: mime,
        cachedPath: i < cachedPaths.length ? cachedPaths[i] : null,
        caption: i == 0 ? caption : null,
        viewOnce: viewOnce,
        albumId: albumId,
      ));
    }
    // Before the photos rather than after. transferImage runs them one at a
    // time and a batch is seconds on the relay, minutes on Bluetooth, so this
    // reaches the other side while the first photo is still moving — it is
    // waiting when the first bubble appears, instead of regrouping bubbles
    // somebody is already looking at.
    //
    // Not for view-once, which never joins an album on either side
    // (`_albumable` in photo_albums.dart excludes it), so a hint for one would
    // be airtime spent on something the receiver would ignore.
    if (!viewOnce) await _announceAlbum(pending);

    for (var i = 0; i < pending.length; i++) {
      try {
        await transferImage(pending[i]);
      } catch (e) {
        // Whatever is left has not been attempted and will not be. Say so on
        // each of them rather than leaving a row of bubbles stuck on "sending"
        // forever.
        final messages = _ref.read(messagesControllerProvider.notifier);
        for (final abandoned in pending.skip(i + 1)) {
          messages.updateStatus(
            abandoned.canonicalId,
            abandoned.message.id,
            MessageStatus.failed,
          );
          if (abandoned.chatId != abandoned.canonicalId) {
            messages.updateStatus(
              abandoned.chatId,
              abandoned.message.id,
              MessageStatus.failed,
            );
          }
        }
        rethrow;
      }
    }
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
    List<double>? levels,
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
    // Folded here rather than at the microphone: the recorder collects a
    // reading per frame and how many bars are worth drawing is a wire
    // question, not a recording one.
    final bars = levels == null || levels.isEmpty
        ? null
        : VoiceLevels.resample(levels);
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
      // Our own copy gets the shape too, from the same numbers that go out —
      // otherwise the sender is the one person in the conversation who cannot
      // see what they just sent.
      audioLevels: bars,
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
      // Match image/file routing: relay-only is valid only when the relay is
      // actually connected. If Bluetooth drops and the relay is still waking,
      // keep the route decision honest so retry/backoff can recover instead of
      // committing a voice note to a dead internet path.
      final relayOnly = !_hasAnyLink && _relayClient?.isConnected == true;
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
      // After the manifest, so a receiver handed both in one burst already has
      // somewhere to put them. Best-effort: a voice note whose shape did not
      // go out is still a voice note, and a throw here would fail a send that
      // is already on its way.
      if (bars != null) {
        unawaited(_announceVoiceLevels(
          canonicalId: canonicalId,
          peerPub: peerPub,
          mediaId: audioId,
          bars: bars,
        ));
      }
      if (fs != null) {
        DebugLog.instance.log(
            'CRYPTO', 'sendAudio: forward-secret (X3DH) media to $canonicalId');
      }
      var audGap = Duration.zero;
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

        final delivery = await _deliverMediaFrameRetrying(
          frameBytes: frameBytes,
          session: session,
          canonicalId: canonicalId,
          relayOnly: relayOnly,
          gap: audGap,
        );
        audGap = delivery.gap;
        if (!delivery.sent) {
          throw const MediaRouteUnavailable();
        }
        // Same ring the photo bubble draws — a voice note over Bluetooth is
        // just as long a wait and said just as little about itself.
        _ref
            .read(mediaSendProgressProvider.notifier)
            .report(msg.id, sent: i + 1, total: total);
        // BLE notify pacing; see sendImage. Over the relay the only gap is
        // backpressure returned by the relay path.
        if (i + 1 < total) {
          final pause =
              relayOnly ? audGap : const Duration(milliseconds: 15) + audGap;
          if (pause > Duration.zero) await Future<void>.delayed(pause);
        }
      }
      _ref.read(mediaSendProgressProvider.notifier).clear(msg.id);
      messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
      }
    } catch (e, st) {
      debugPrint('sendAudio failed: $e\n$st');
      _ref.read(mediaSendProgressProvider.notifier).clear(msg.id);
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
  /// Chats with a receipt sweep already running.
  ///
  /// The sweep is triggered from several places at once — a chat opening, a
  /// relay connecting, a message arriving into the open chat — and it awaits
  /// two box loads and a publish per slice. Without a guard those calls
  /// overlap, and each one snapshots the unacknowledged set before any of the
  /// others has recorded what it sent. A field log shows the shape exactly:
  /// six sweeps of one chat inside 1.2 seconds, sending 1, 2, 3, 4, 4 and 4
  /// acknowledgements — the same handful of ids published six times over.
  ///
  /// **Coalesced, not dropped**, and 987 got that wrong.
  ///
  /// It read "dropping the overlapping call rather than queueing it, because
  /// they are all asking the same question and the one already running will
  /// answer it with the newer state anyway". The second half is false. A sweep
  /// awaits two box loads *before* it reads the message list, so it answers
  /// for the state at the moment it got that far — and a call arriving during
  /// that window carries news it has already gone past.
  ///
  /// Which is exactly the case that matters: four stickers land inside two
  /// hundred milliseconds, the chat opens, the first sweep runs against
  /// whatever had arrived when it started, and the calls for the other three
  /// are thrown away. One acknowledgement for four messages — reported as
  /// "не прочитуються смс", and it is this, not the watermark.
  ///
  /// So a request during a sweep sets a flag, and the sweep runs once more
  /// when it finishes. Once, however many arrived: the re-run reads the list
  /// fresh, so it covers all of them, and the loop cannot spin because a run
  /// that nothing asked to repeat ends.
  final Set<String> _receiptSweeps = <String>{};
  final Set<String> _receiptSweepAgain = <String>{};

  Future<void> sendReadReceipts(String canonicalId) async {
    if (!_receiptSweeps.add(canonicalId)) {
      _receiptSweepAgain.add(canonicalId);
      return;
    }
    try {
      while (true) {
        await _timed('sendReadReceipts', () => _sendReadReceipts(canonicalId));
        if (_disposed) return;
        if (!_receiptSweepAgain.remove(canonicalId)) return;
      }
    } finally {
      _receiptSweeps.remove(canonicalId);
      _receiptSweepAgain.remove(canonicalId);
    }
  }

  /// How long one of these actually blocked the thread it ran on.
  ///
  /// Both of the calls chat-open schedules are `async`, and an `async` function
  /// runs synchronously until its first real suspension — so "it is awaited"
  /// says nothing about whether it stalls a frame. An X3DH encrypt and a
  /// BIP-340 signature are pure Dart and have no suspension in them at all.
  ///
  /// Two numbers, because the difference between them is the answer. `sync` is
  /// the part that ran before the first await returned control, which is the
  /// part a frame pays for; `total` includes waiting on the radio and the
  /// relay, which costs nothing to look at.
  ///
  /// Instrumentation, not a fix. A change reasoned from the panel's worst-frame
  /// number moved it by 3 ms — noise — and nothing said whether the theory was
  /// wrong or the aim was. This is what says so.
  Future<void> _timed(String what, Future<void> Function() run) {
    final clock = Stopwatch()..start();
    final future = run();
    final syncUs = clock.elapsedMicroseconds;
    return future.whenComplete(() {
      final totalUs = clock.elapsedMicroseconds;
      if (syncUs < 4000 && totalUs < 40000) return;
      DebugLog.instance.log(
        'COST',
        '$what — sync ${(syncUs / 1000).toStringAsFixed(1)} ms, '
            'total ${(totalUs / 1000).toStringAsFixed(1)} ms',
      );
    });
  }

  Future<void> _sendReadReceipts(String canonicalId) async {
    // Opted out of read receipts: say nothing. The messages are still marked
    // read locally — this only withholds telling anyone else about it.
    // The global switch and this contact's exception at once — see
    // [ConversationSettingsController.sharesReadReceiptsWith], which is where
    // "only ever more private" lives.
    if (!_ref
        .read(conversationSettingsControllerProvider.notifier)
        .sharesReadReceiptsWith(canonicalId)) {
      // Both halves of the switch are silent by design — see the ingest side —
      // so without this the setting looks exactly like a broken feature.
      DebugLog.instance.log('RECEIPT', 'not sending: read receipts are off');
      return;
    }
    final msgs = _ref.read(messagesControllerProvider)[canonicalId];
    if (msgs == null || msgs.isEmpty) return;

    final isChannel = canonicalId.startsWith('#');
    final channel = isChannel
        ? _ref.read(channelControllerProvider.notifier).byName(canonicalId)
        : null;
    if (isChannel && channel == null) return; // left it, or never joined

    // Only what the user has actually read.
    //
    // The read marker is the record of that, and it was not consulted here at
    // all: this acknowledged every inbound message that had not been
    // acknowledged yet, and the retry sweep runs it over *every* chat whenever
    // a route appears. So messages sitting unopened were reported as read —
    // the other phone showed two ticks for a conversation nobody had looked
    // at. No marker means the chat has never been opened, and there is nothing
    // honest to report about it.
    // Waited for, not read early — and this is the whole of the cold-start
    // storm.
    //
    // The sweep runs when a relay connects, which is about a second after
    // launch, while both of these boxes are still opening. They are read
    // together and they answer two halves of one question: how far the person
    // has read, and how far that has been reported. Loaded out of step they
    // say the worst possible thing — everything read, nothing acknowledged —
    // and the entire conversation is acknowledged again.
    //
    // Measured on a phone with about two hundred messages in one chat: sixteen
    // relay publishes inside 1.1 seconds, `sendReadReceipts total 2089 ms`, on
    // every single launch. It also filled the 200-line debug log in three
    // seconds, so every log sent in to diagnose anything else arrived holding
    // nothing but this.
    //
    // The marker that exists to prevent exactly this was added and is correct;
    // it was simply being read before it was there. `announceCopyRestriction`
    // learned the same lesson about its own settings box a while ago and has
    // the same `await` two dozen lines up.
    final readMarkers = _ref.read(readMarkersControllerProvider.notifier);
    final ackMarkers = _ref.read(ackMarkersControllerProvider.notifier);
    await readMarkers.loaded;
    await ackMarkers.loaded;
    if (_disposed) return;

    final readUpTo = _ref.read(readMarkersControllerProvider)[canonicalId];
    if (readUpTo == null) return;

    // Where this chat's receipts got to last time, across restarts — see
    // [AckMarkersController]. Without it the set below starts empty on every
    // launch and the whole history is acknowledged again, which is what the
    // freeze on cold start turned out to be.
    final ackedUpTo = _ref.read(ackMarkersControllerProvider)[canonicalId];

    // The oldest message the exact record can vouch for. Null means it vouches
    // for nothing yet, and then the watermark decides everything — which is
    // the state of every phone on its first launch after this shipped.
    final coverFrom = ackMarkers.ackCoverFrom;

    final fresh = <({Uint8List id, DateTime at})>[];
    var skippedUnread = 0;
    var skippedSession = 0;
    var skippedAcked = 0;
    var skippedWatermark = 0;
    for (final m in msgs) {
      if (m.isMine) continue;
      if (m.sentAt.isAfter(readUpTo)) {
        skippedUnread++;
        continue;
      }
      final w = m.wireId;
      if (w == null) continue;
      if (_sentReadAcks.contains(w)) {
        skippedSession++;
        continue;
      }
      // Ask the exact record first, and only fall back on the watermark for
      // what the record no longer covers.
      //
      // The watermark alone said "older than the last thing acknowledged,
      // therefore already acknowledged", which is only true if messages arrive
      // in the order they were sent. Since 956 they carry the sender's clock,
      // so anything held on a relay arrives stamped *before* things already
      // acknowledged — and a batch of media is delivered precisely that way. A
      // shipped pair of logs had four stickers sent at 21:12:03 landing at
      // 21:14:35 after two restarts: the chat was opened, four banners
      // cleared, and one receipt went out. The other three were not late,
      // they were unreachable.
      if (ackMarkers.hasAcked(w)) {
        skippedAcked++;
        continue;
      }
      // Inside what the record covers, its silence means "not acknowledged".
      // Outside it, silence means nothing at all and the watermark answers.
      // Getting that the wrong way round is what 984 shipped, and it re-acked
      // every message on the first launch after the update.
      final covered = coverFrom != null && m.sentAt.isAfter(coverFrom);
      if (!covered && ackedUpTo != null && !m.sentAt.isAfter(ackedUpTo)) {
        skippedWatermark++;
        continue;
      }
      try {
        fresh.add((id: _hexDecodeBytes(w), at: m.sentAt));
      } catch (_) {/* skip malformed wireId */}
    }
    if (fresh.isEmpty) {
      // Silence was the whole problem. "Nothing to acknowledge" and "four
      // things to acknowledge and every one of them refused by a filter" left
      // the same empty log, so a report of ticks not turning blue had nothing
      // to work from but the absence of a line. Each filter now says how many
      // it took.
      if (skippedUnread + skippedAcked + skippedWatermark > 0) {
        DebugLog.instance.log(
          'RECEIPT',
          'nothing to ack for ${_short(canonicalId)} — '
              '$skippedUnread not read yet, $skippedSession sent this run, '
              '$skippedAcked already acked, $skippedWatermark below the mark',
        );
      }
      return;
    }

    // The newest message whose receipt actually went somewhere. Advanced only
    // on a slice that reported a fan-out, so a run that dies halfway leaves the
    // marker where the sending stopped rather than where it was aiming.
    DateTime? acked;

    final peerPub = isChannel ? null : _resolvePeerPub(canonicalId);
    if (!isChannel && peerPub == null) return;

    for (var i = 0; i < fresh.length; i += ReadReceipt.maxIdsPerFrame) {
      final end = (i + ReadReceipt.maxIdsPerFrame).clamp(0, fresh.length);
      final slice = fresh.sublist(i, end);
      final receipt = ReadReceipt(
        status: ReceiptStatus.read,
        msgIds: [for (final e in slice) e.id],
      );
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
          final landed = <String, DateTime>{};
          for (final e in slice) {
            final hex = TransportEnvelope.hashHex(e.id);
            _sentReadAcks.add(hex);
            landed[hex] = e.at;
            final seen = acked;
            if (seen == null || e.at.isAfter(seen)) acked = e.at;
          }
          // Written down across restarts, not only for this run. The in-memory
          // set dies with the process, and the launch after it is exactly when
          // a receipt that never went out has to be noticed.
          await ackMarkers.markIdsAcked(landed);
          DebugLog.instance.log(
            'RECEIPT',
            'sent ${slice.length} read ack(s) to ${_short(canonicalId)} '
            '(fanout $fanout)',
          );
        } else {
          // Stop the whole sweep at the first slice that finds no route, and
          // do not log the rest. Nothing has changed between one slice and the
          // next — there is still no route — so continuing only produces the
          // storm this line was drowning in, and the next attempt happens when
          // a route actually appears.
          DebugLog.instance.log('RECEIPT',
              'no route for ${slice.length} read ack(s) — will retry');
          // Whatever did go out before this slice still counts, or the next
          // launch re-sends it.
          await _rememberAcked(canonicalId, acked);
          return;
        }
      } catch (e) {
        DebugLog.instance.log('RECEIPT', 'read-receipt send failed: $e');
      }
    }
    await _rememberAcked(canonicalId, acked);
  }

  /// Persist how far this chat's receipts got, so the next launch starts from
  /// there instead of from the beginning of the conversation.
  Future<void> _rememberAcked(String canonicalId, DateTime? acked) async {
    if (acked == null) return;
    await _ref
        .read(ackMarkersControllerProvider.notifier)
        .markAcked(canonicalId, acked);
  }

  /// Re-offer every read acknowledgement that has not gone out yet.
  ///
  /// Cheap enough to run on a relay coming up: [sendReadReceipts] filters to
  /// messages it has not already acknowledged this run, so a chat with nothing
  /// outstanding costs one map lookup and returns.
  /// Guards against the sweep re-entering itself and against it running back
  /// to back. Both were happening: a field log from an iPhone that had just
  /// connected showed `no route for 2 read ack(s) — will retry ×172` inside a
  /// single millisecond, and the phone was unusable while it did that.
  ///
  /// Nothing here retries on a timer — the sweep is called when a route
  /// appears — so a failed pass costs nothing by waiting. What it must not do
  /// is run again the instant it finishes, over every chat, while the route
  /// that failed it is still missing.
  bool _flushingReadReceipts = false;
  DateTime? _lastReadReceiptFlush;
  static const Duration _readReceiptFlushGap = Duration(seconds: 5);

  /// Carry queued messages over a relay that has just come up.
  ///
  /// Until this existed, a message that found no route was handed to
  /// store-and-forward and waited there for the recipient to walk into
  /// Bluetooth range — the relay coming back was not a second chance, only a
  /// BLE handshake was. For two people who never meet in person that is not a
  /// delay, it is never.
  ///
  /// It is the weak-connection case that makes this common. The socket takes
  /// longer to open than a person takes to press send, so on a bad link the
  /// *first* message of a session routinely misses the relay that is up eight
  /// seconds later.
  ///
  /// One at a time: the link that just came up is by assumption a poor one,
  /// and thirty parallel publishes on it is how it goes down again.
  ///
  /// A failure moves on to the next message rather than ending the round,
  /// because the commonest reason a particular one cannot go is that its
  /// recipient has no Nostr key on file — and that peer would otherwise stand
  /// at the head of the queue holding up everybody reachable behind them. Three
  /// failures in a row is a different statement: that is the link, not the
  /// recipients, so the round stops and waits for the next relay-up.
  ///
  /// Nothing carried is lost — it stays queued for the next attempt or for the
  /// next Bluetooth handshake, whichever comes first.
  Future<void> _flushOutboxOverRelay() async {
    if (_disposed || _outbox.isEmpty) return;
    if (_flushingOutbox) return;
    _flushingOutbox = true;
    final messages = _ref.read(messagesControllerProvider.notifier);
    final delivered = <String, Set<String>>{};
    var failures = 0;
    try {
      // A copy, because a send that succeeds mutates the map underneath us.
      for (final entry in _outbox.entries.toList()) {
        if (_disposed) return;
        final ref = entry.value;
        // No doorbell on a retry, and this was got wrong once. Marking the
        // outbox as wake-worthy looked right — a queued message is a real
        // message somebody has not seen — and in practice it rings for mail
        // that arrived long ago by another road. The queue holds what the mesh
        // could not carry, and that includes frames a Bluetooth handshake
        // delivered afterwards; one launch replayed 152 of them across four
        // peers, each ringing a phone whose app then dropped it as
        // already-stored. Reported as notifications for messages that had
        // already arrived, or that did not exist at all — the same thing seen
        // from the lock screen.
        //
        // The doorbell rang once when the message was first sent. Ringing
        // again on every relay reconnect is not a second message.
        if (!await _sendOverNostr(ref.canonicalId, ref.frameBytes)) {
          DebugLog.instance.log(
            'NOSTR',
            'queued message for ${ref.canonicalId} still has no relay road',
          );
          if (++failures >= 3) return;
          continue;
        }
        failures = 0;
        _outbox.remove(entry.key);
        // Collected, not applied. Reporting each landing on its own woke
        // every screen watching the message store once per message; the batch
        // goes in after the loop — see [MessagesController.markDeliveredBatch].
        for (final id in {ref.canonicalId, ref.chatId}) {
          (delivered[id] ??= <String>{}).add(ref.messageId);
        }
        DebugLog.instance.log(
          'NOSTR',
          'queued message to ${ref.canonicalId} went out by relay',
        );
      }
    } finally {
      _flushingOutbox = false;
      // Applied on every exit, including the early return that gives up after
      // three failures: what did go out has gone out, and the sender is owed
      // the tick for it.
      messages.markDeliveredBatch(delivered, MessageRoute.internet);
    }
  }

  bool _flushingOutbox = false;

  Future<void> _flushPendingReadReceipts() async {
    if (_disposed) return;
    if (!_ref.read(privacySettingsProvider).shareReadReceipts) return;
    if (_flushingReadReceipts) return;
    final since = _lastReadReceiptFlush;
    if (since != null &&
        DateTime.now().difference(since) < _readReceiptFlushGap) {
      return;
    }
    _flushingReadReceipts = true;
    _lastReadReceiptFlush = DateTime.now();
    try {
      await _flushPendingReadReceiptsInner();
    } finally {
      _flushingReadReceipts = false;
    }
  }

  Future<void> _flushPendingReadReceiptsInner() async {
    if (_disposed) return;
    for (final chatId in _ref.read(messagesControllerProvider).keys.toList()) {
      if (_disposed) return;
      try {
        await sendReadReceipts(chatId);
      } catch (e) {
        DebugLog.instance.log('RECEIPT', 'flush for $chatId failed: $e');
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
  /// [kind] says which activity, and null ends whichever was showing.
  ///
  /// One byte, in the body this frame always had — see [PeerActivity] for why
  /// that is a value and not a payload type of its own, and for what a build
  /// that predates recording does with an unfamiliar one (it takes the
  /// indicator down, which is the right way to be wrong).
  ///
  /// Recording is exempt from [typingMinInterval]. The throttle exists because
  /// the composer calls this on every keystroke; a recording announces itself
  /// once when the finger goes down, and holding that back for three seconds
  /// would mean the shortest voice notes never showed at all.
  Future<void> announceTyping(
    String canonicalId, {
    bool typing = true,
    PeerActivity kind = PeerActivity.typing,
  }) async {
    if (_disposed) return;
    // Global switch and this contact's exception together: somebody who is not
    // shown our times is not shown our typing either, which is the same
    // question asked a second apart.
    if (!_ref
        .read(conversationSettingsControllerProvider.notifier)
        .sharesLastSeenWith(canonicalId)) {
      return;
    }
    if (!AppLifecycle.instance.isForeground) return;
    if (canonicalId.startsWith('#')) return; // 1:1 only

    if (typing) {
      final last = _lastTypingSentAt[canonicalId];
      if (kind == PeerActivity.typing &&
          last != null &&
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
        innerBody: Uint8List.fromList([typing ? kind.wireByte : 0x00]),
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
    DateTime? sentAt,
  }) {
    if (body.isEmpty) return;
    final canonicalId = senderPub != null ? _hexOf(senderPub) : peerId;
    final controller = _ref.read(typingControllerProvider.notifier);
    final kind = PeerActivity.fromWire(body[0]);
    if (kind == null) {
      // A stop is applied whatever its age. It can only take the indicator
      // down, and taking it down late is better than leaving it up. A byte a
      // later build sends and this one does not know lands here too, on
      // purpose — see [PeerActivity.fromWire].
      controller.clear(canonicalId);
      return;
    }

    // "I am writing" is a claim about this second, and it was being believed
    // whenever it happened to arrive.
    //
    // The notice was stamped with our own clock, so one held on a relay came
    // out of the backlog looking new. Reported as the indicator appearing
    // while nobody was typing, and a log of a relay reconnect shows the shape
    // of it: presence beacons in the same burst were stale by two, four, five,
    // six and seven minutes. Presence filters those; this did not, so a
    // seven-minute-old keystroke lit the line for its full eight seconds.
    final now = DateTime.now();
    final stamp = (sentAt == null || sentAt.isAfter(now)) ? now : sentAt;
    if (now.difference(stamp) >= TypingController.ttl) return;
    controller.record(canonicalId, at: stamp, kind: kind);
  }

  /// Peers we have already told about our copy restriction this run.
  ///
  /// There is no acknowledgement to wait on, so what stands in for one is
  /// repetition: the switch itself, a session coming up, and the first time the
  /// chat is opened. This keeps those from piling onto each other — but an
  /// entry only survives a send that reached *something*, or the first attempt
  /// (typically the chat opening with the peer nowhere in range) would spend
  /// the only chance the other two were there to provide.
  /// What each peer was last *told*, not merely which peers were told
  /// something.
  ///
  /// A set could only remember "this peer has heard from us", which made
  /// switching the restriction back off unrepeatable. Turning it on is
  /// re-stated on every session and every opening of the chat, because a peer
  /// who was away for the announcement must still end up honouring it. Turning
  /// it off was announced exactly once, fire-and-forget, and this notice has no
  /// acknowledgement — so a single lost frame left the other phone refusing to
  /// forward a conversation whose owner had allowed it again, permanently, with
  /// no way back short of reinstalling. A tester hit precisely that: allowed
  /// forwarding on the iPhone, and the Android went on saying copying was
  /// forbidden.
  ///
  /// Holding the value makes both directions repeatable and still costs one
  /// small control frame per peer per run: a repeat is dropped when it would
  /// say what this peer was already told, and sent when it would not.
  final Map<String, bool> _copyRestrictionAnnounced = <String, bool>{};

  /// Tell one peer whether copying and forwarding are off in this conversation.
  ///
  /// The setting used to be enforced only on the phone that set it, which is
  /// the one side that already knows. The other side kept Copy and Forward and
  /// could pass the conversation on — the exact thing the switch is for — so
  /// the request has to travel.
  ///
  /// [force] is the switch being thrown: it always sends, including the "back
  /// on" that lifts a restriction. Without it this is the opportunistic resend
  /// — at most once per peer per app run, whichever answer it is.
  ///
  /// It used to say here that "not restricted" was never sent, because a fresh
  /// contact does not need telling that a default is still the default. That
  /// stopped being true when the dedup below learned to remember *which* answer
  /// a peer was given, and the reason is two lines down: lifting a ban rested
  /// on one unacknowledged frame, so a peer who missed it went on refusing to
  /// forward for good. The stale sentence was read off a log by somebody
  /// counting relay traffic, who took four notices to four different peers for
  /// one notice repeated four times.
  ///
  /// [restricted] is only passed by the switch, which knows the new value
  /// before the store has finished writing it. Everyone else leaves it null and
  /// gets the stored answer, waited for rather than read early — a handshake
  /// can land before the settings box has finished opening, and reading through
  /// it would announce "not restricted" for a conversation that is.
  Future<void> announceCopyRestriction(
    String canonicalId, {
    bool? restricted,
    bool force = false,
  }) =>
      _timed(
        'announceCopyRestriction',
        () => _announceCopyRestriction(
          canonicalId,
          restricted: restricted,
          force: force,
        ),
      );

  Future<void> _announceCopyRestriction(
    String canonicalId, {
    bool? restricted,
    bool force = false,
  }) async {
    if (_disposed || canonicalId.startsWith('#')) return;
    bool on;
    if (restricted != null) {
      on = restricted;
    } else {
      final settings =
          _ref.read(conversationSettingsControllerProvider.notifier);
      await settings.loaded;
      on = settings.forChat(canonicalId).restrictCopying;
    }
    // Dropped only when this peer has already been told this exact answer in
    // this run — including "off", which is the case the old set could not
    // express.
    if (!force && _copyRestrictionAnnounced[canonicalId] == on) return;
    _copyRestrictionAnnounced[canonicalId] = on;
    final peerPub = _disposed ? null : _resolvePeerPub(canonicalId);
    if (peerPub == null) {
      _copyRestrictionAnnounced.remove(canonicalId);
      return;
    }
    try {
      final fanout = await _sendControlToPeer(
        canonicalId: canonicalId,
        peerPub: peerPub,
        type: InnerPayloadType.copyRestriction,
        innerBody: Uint8List.fromList([on ? 0x01 : 0x00]),
      );
      // Zero is an ordinary return from the fan-out, not an error: no link, no
      // relay, nobody told. Forgetting it here is what lets the next session or
      // the next opening of the chat try again.
      if (fanout == 0) _copyRestrictionAnnounced.remove(canonicalId);
      DebugLog.instance.log(
          'CHAT',
          'told $canonicalId copying is '
              '${on ? "off" : "back on"} ($fanout)');
    } catch (e) {
      _copyRestrictionAnnounced.remove(canonicalId);
      DebugLog.instance.log('CHAT', 'copy-restriction notice failed: $e');
    }
  }

  /// Tell everybody we talk to whether a forward of our words may carry a way
  /// back to us.
  ///
  /// To every contact rather than to one conversation, because it is a fact
  /// about us and not about a room: the person who forwards is whoever we said
  /// it to, and any of them might.
  ///
  /// Best effort per peer, and re-sent whenever the switch moves. Somebody
  /// unreachable at that moment keeps the answer they last heard, which is the
  /// same guarantee the copy restriction gives and the only one available with
  /// no server to hold the setting.
  Future<void> broadcastForwardPrivacy({bool? allowed}) async {
    if (_disposed) return;
    final settings = _ref.read(privacySettingsProvider);
    final on = allowed ?? settings.allowForwardLink;
    final peers = _ref.read(knownPeersControllerProvider);
    var told = 0;
    for (final peer in peers.values) {
      if (peer.isBlocked) continue;
      final peerPub = _resolvePeerPub(peer.pubkeyHex);
      if (peerPub == null) continue;
      try {
        final fanout = await _sendControlToPeer(
          canonicalId: peer.pubkeyHex,
          peerPub: peerPub,
          type: InnerPayloadType.forwardPrivacy,
          innerBody: Uint8List.fromList([on ? 0x01 : 0x00]),
        );
        if (fanout > 0) told++;
      } catch (e) {
        DebugLog.instance.log('CHAT', 'forward-privacy notice failed: $e');
      }
    }
    DebugLog.instance.log(
      'CHAT',
      'forward links are ${on ? 'allowed' : 'refused'} — told $told peer(s)',
    );
  }

  /// Remove somebody from a room, or silence them until [until].
  ///
  /// Administrators only, and never against another administrator: seniority is
  /// not a thing this protocol can establish, so the seat protects its holder —
  /// otherwise two admins take turns removing each other and every phone in the
  /// room ends up with a different answer.
  ///
  /// Applied here as well as broadcast. The sender is a member like any other
  /// and enforces the same rule against the same roster; waiting for our own
  /// frame to come back would leave the moderator as the one person still
  /// accepting the posts.
  Future<void> sendChannelModeration(
    String channelName, {
    required String memberId,
    required ChannelModerationAction action,
    DateTime? until,
  }) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    if (!roster.isAdmin(channel.name, me.id)) {
      throw StateError('only an admin can moderate $channelName');
    }
    if (roster.isAdmin(channel.name, memberId)) {
      throw StateError('an administrator cannot be removed or silenced');
    }
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.channelModeration,
      ChannelModeration(
        memberId: memberId,
        action: action,
        until: action == ChannelModerationAction.mute ? until : null,
      ).encode(),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    await roster.moderate(
      channel.name,
      memberId: memberId,
      removed: action == ChannelModerationAction.remove,
      mutedUntil: action == ChannelModerationAction.mute ? until : null,
      clear: action == ChannelModerationAction.clear,
    );
    final fanout = await _broadcastChannelFrame(frame);
    DebugLog.instance.log(
      'CHAN',
      '${channel.name}: $memberId ${action.name} (told $fanout)',
    );
  }

  /// Hand the room's backlog to whoever is missing it.
  ///
  /// A deliberate act by an administrator rather than something that happens on
  /// its own, because it is the one thing here that puts a room's whole history
  /// back on the air: the cost is paid by every phone in range, and only the
  /// person who runs the room can judge whether it is worth paying.
  ///
  /// Harmless where it is not needed. Every post carries the wireId it
  /// originally travelled under and message insertion is idempotent on that, so
  /// a member who was there stores nothing and sees nothing.
  ///
  /// Text only, and the most recent [ChannelHistory.maxPosts]. Pictures are
  /// chunked streams with their own manifests; replaying those is a different
  /// job and a far larger one.
  Future<int> sendChannelHistory(String channelName) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    if (!channel.adminOnly) {
      throw StateError('history is only shareable in an announcement channel');
    }
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    if (!roster.isAdmin(channel.name, me.id)) {
      throw StateError('only an admin can share the history of $channelName');
    }
    // Before the backlog, who is offering it.
    //
    // The receiving side takes a history only from somebody it already holds
    // as an administrator, and a member who has never been told who that is
    // holds nobody. Announcing the seat first is what makes the offer landable
    // — the same order [sendChannelAdminOnly] uses, and for the same reason.
    await announceChannelSeat(channel.name);
    final stored =
        _ref.read(messagesControllerProvider)[channel.name] ?? const <Message>[];
    final posts = <ChannelHistoryPost>[];
    final photos = <Message>[];
    for (final message in stored.reversed) {
      if (posts.length >= ChannelHistory.maxPosts) break;
      // Pictures go the way pictures go: a manifest and its chunks, re-sent
      // under the id they first travelled under, so a phone that already holds
      // one takes the manifest and discards it. Collected here and sent after
      // the text, because the text is small and should not wait behind
      // several megabytes of photographs.
      if (message.kind == MessageKind.image) {
        if (photos.length < _maxReplayedPhotos &&
            message.mediaId != null &&
            MediaPaths.existsOrNull(message.imagePath)) {
          photos.add(message);
        }
        continue;
      }
      if (message.kind != MessageKind.text) continue;
      final wireId = message.wireId;
      if (wireId == null || wireId.length != 32) continue;
      if (message.text.trim().isEmpty) continue;
      if (utf8.encode(message.text).length > ChannelHistory.maxTextBytes) {
        continue;
      }
      posts.add(
        ChannelHistoryPost(
          wireId: _hexDecodeBytes(wireId),
          sentAt: message.sentAt,
          text: message.text,
        ),
      );
    }
    if (posts.isEmpty && photos.isEmpty) return 0;
    var fanout = 0;
    if (posts.isNotEmpty) {
      final frame = await _buildChannelFrame(
        channel,
        InnerPayloadType.channelHistory,
        // Oldest first, so a reader who takes only part of it takes a
        // beginning.
        ChannelHistory(posts: posts.reversed.toList()).encode(),
        TransportEnvelope.newMsgId(initialTtl: _meshTtl),
      );
      fanout = await _broadcastChannelFrame(frame);
    }
    // Oldest first here too, and one at a time: a photo is hundreds of chunks
    // and the room has to carry every one of them.
    for (final photo in photos.reversed) {
      try {
        final path = MediaPaths.repairOrNull(photo.imagePath);
        if (path == null) continue;
        await sendChannelImage(
          channel.name,
          bytes: await File(path).readAsBytes(),
          mime: photo.imageMime ?? 'image/jpeg',
          caption: photo.imageCaption,
          reuseImageId: _hexDecodeBytes(photo.mediaId!),
        );
      } catch (e) {
        // One unreadable picture does not take the offer down with it.
        DebugLog.instance.log('CHAN', 'history photo skipped: $e');
      }
    }
    DebugLog.instance.log(
      'CHAN',
      'offered ${posts.length} posts and ${photos.length} photos of '
          '${channel.name} history (to $fanout)',
    );
    return posts.length + photos.length;
  }

  /// How many pictures one history offer will re-send.
  ///
  /// Far fewer than the fifty posts beside them, because a photo is hundreds
  /// of chunks and every one of them is broadcast to the whole room. Ten is a
  /// scroll's worth of recent pictures and a few megabytes of airtime; fifty
  /// would be a room unusable for several minutes.
  static const int _maxReplayedPhotos = 10;

  static ConversationWallpaperPayload _wallpaperPayload(
      ChatWallpaper wallpaper) {
    final preset = wallpaper.presetIndex;
    if (preset == null) return const ConversationWallpaperPayload.clear();
    return ConversationWallpaperPayload(
        presetIndex: preset, dim: wallpaper.dim);
  }

  static ChatWallpaper _wallpaperFromPayload(
    ConversationWallpaperPayload payload,
  ) {
    final preset = payload.presetIndex;
    if (preset == null) return ChatWallpaper.none;
    final clamped = preset.clamp(0, ChatWallpaper.presets.length - 1);
    return ChatWallpaper(presetIndex: clamped, dim: payload.dim);
  }

  /// Share a lightweight built-in wallpaper preset with a peer or channel.
  ///
  /// Custom photo wallpapers are intentionally not sent here: this path is a
  /// single small control frame. Photos need the chunked media path so they do
  /// not turn a cosmetic setting into a huge packet that can stall BLE and hot
  /// devices while the user is scrolling.
  Future<bool> sendSharedWallpaper(
    String chatId,
    ChatWallpaper wallpaper,
  ) async {
    if (wallpaper.imagePath != null) {
      throw StateError('shared photo wallpapers are not chunked yet');
    }
    final body = _wallpaperPayload(wallpaper).encode();
    final settings = _ref.read(conversationSettingsControllerProvider.notifier);
    await settings.loaded;

    if (chatId.startsWith('#')) {
      final channel =
          _ref.read(channelControllerProvider.notifier).byName(chatId);
      if (channel == null) throw StateError('not a member of $chatId');
      final roster = _ref.read(channelRosterControllerProvider.notifier);
      final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
      if (!roster.isAdmin(channel.name, me.id)) {
        throw StateError('only an admin can set wallpaper for $chatId');
      }
      await settings.setWallpaper(channel.name, wallpaper);
      final frame = await _buildChannelFrame(
        channel,
        InnerPayloadType.conversationWallpaper,
        body,
        TransportEnvelope.newMsgId(initialTtl: _meshTtl),
      );
      final fanout = await _broadcastChannelFrame(frame);
      DebugLog.instance.log(
        'CHAN',
        'shared wallpaper for ${channel.name}: ${wallpaper.presetIndex ?? "clear"} (fanout=$fanout)',
      );
      return fanout > 0;
    }

    await settings.setWallpaper(chatId, wallpaper);
    final peerPub = _resolvePeerPub(chatId);
    if (peerPub == null) return false;
    final fanout = await _sendControlToPeer(
      canonicalId: chatId,
      peerPub: peerPub,
      type: InnerPayloadType.conversationWallpaper,
      innerBody: body,
    );
    DebugLog.instance.log(
      'CHAT',
      'shared wallpaper with $chatId: ${wallpaper.presetIndex ?? "clear"} ($fanout)',
    );
    return fanout > 0;
  }

  Future<void> _ingestConversationWallpaper({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) async {
    final payload = ConversationWallpaperPayload.decode(body);
    final wallpaper = _wallpaperFromPayload(payload);
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    final settings = _ref.read(conversationSettingsControllerProvider.notifier);
    await settings.loaded;
    await settings.setWallpaper(canonical, wallpaper);
    if (canonical != peerId) await settings.setWallpaper(peerId, wallpaper);
    DebugLog.instance.log(
      'CHAT',
      '$canonical shared wallpaper ${wallpaper.presetIndex ?? "clear"}',
    );
  }

  /// Turn copying and forwarding off (or back on) for a whole room.
  ///
  /// The 1:1 notice cannot carry this: [announceCopyRestriction] addresses one
  /// peer and returns early for a channel id, because there is nobody in
  /// particular to address. A room's answer is a broadcast like its picture and
  /// its topic, signed by the sender, and authorised the same way — by an admin,
  /// or by anyone when the room has none.
  ///
  /// Members store it in the same field a peer's request lands in, so the
  /// person who was told not to forward cannot quietly switch it off for
  /// themselves.
  Future<void> sendChannelCopyRestriction(
    String channelName,
    bool restricted,
  ) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    // A real check again, exactly as for the picture and the topic.
    if (!roster.isAdmin(channel.name, me.id)) {
      throw StateError('only an admin can restrict copying in $channelName');
    }
    final settings = _ref.read(conversationSettingsControllerProvider.notifier);
    await settings.loaded;
    await settings.setRestrictCopying(channel.name, restricted);
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.copyRestriction,
      Uint8List.fromList([restricted ? 0x01 : 0x00]),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    final fanout = await _broadcastChannelFrame(frame);
    DebugLog.instance.log(
        'CHAN',
        'copying in ${channel.name} is now '
            '${restricted ? "restricted" : "allowed"} (fanout=$fanout)');
  }

  /// Whether a payload is somebody *posting* into a room, as opposed to
  /// administering it or reacting to it.
  ///
  /// Named rather than inlined because the admin-only rule has to agree with
  /// itself in two places — the send-side courtesy check and the receive-side
  /// enforcement — and a list that drifts between them is a room where posts
  /// vanish for reasons nobody can reproduce.
  static bool _isChannelPost(InnerPayloadType type) => switch (type) {
        InnerPayloadType.text ||
        InnerPayloadType.textReply ||
        InnerPayloadType.mediaManifest ||
        InnerPayloadType.imageChunk ||
        InnerPayloadType.audioChunk ||
        InnerPayloadType.channelPoll =>
          true,
        _ => false,
      };

  /// Turn a room into an announcement channel, or back into a group.
  ///
  /// Broadcast and authorised exactly like the picture and the topic. Members
  /// store it and then enforce it themselves on every frame that arrives — see
  /// [Channel.adminOnly] for why the receiving side is the only side that can.
  Future<void> sendChannelAdminOnly(String channelName, bool adminOnly) async {
    final channels = _ref.read(channelControllerProvider.notifier);
    final channel = channels.byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    if (!roster.isAdmin(channel.name, me.id)) {
      throw StateError(
          'only an admin can set the posting rule for $channelName');
    }
    await channels.setAdminOnly(channel.name, adminOnly);
    // Say who is imposing it, before imposing it.
    //
    // The rule is enforced by each reader against their own roster, and a
    // member who has never been told who the admin is drops everything —
    // including this room's only admin. Announcing the seat first is what
    // makes the rule land on a room where the answer is known.
    if (adminOnly) {
      await _announceOwnAdminSeat(channel.name);
    }
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.channelAdminOnly,
      Uint8List.fromList([adminOnly ? 0x01 : 0x00]),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    final fanout = await _broadcastChannelFrame(frame);
    DebugLog.instance.log(
        'CHAN',
        '${channel.name} is now '
            '${adminOnly ? "admin-only" : "open to everyone"} (fanout=$fanout)');
  }

  /// The peer asked that this conversation not be copied or forwarded.
  ///
  /// Stored beside our own setting rather than into it, so neither side can
  /// switch off what the other asked for. Only ever applies to the chat it
  /// arrived on: like the conversation clear, there is no id in the body that
  /// could point somewhere else.
  Future<void> _ingestCopyRestriction({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) async {
    if (body.isEmpty) return;
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    final restricted = body[0] == 0x01;
    final settings = _ref.read(conversationSettingsControllerProvider.notifier);
    await settings.loaded;
    await settings.setPeerRestrictsCopying(canonical, restricted);
    if (canonical != peerId) {
      await settings.setPeerRestrictsCopying(peerId, restricted);
    }
    DebugLog.instance.log(
        'CHAT',
        '$canonical asks that this chat is '
            '${restricted ? "not copied or forwarded" : "copyable again"}');
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
      DebugLog.instance.log(
          'CHAT', 'asked $canonicalId to clear the conversation ($fanout)');
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
    DateTime? sentAt,
  }) async {
    final messages = _ref.read(messagesControllerProvider.notifier);
    final canonical = senderPub != null ? _hexOf(senderPub) : peerId;
    // Bounded by the moment the clear was sent, which is what keeps a second
    // delivery of it from taking anything — see [clearForChatUpTo]. Clamped
    // to now for the same reason presence clamps: the stamp is the sender's
    // `created_at`, a claim rather than a fact, and one dated in the future
    // would erase messages that have not been written yet.
    //
    // Falling back to now with no stamp is the BLE path, which has no backlog
    // to replay and so behaves exactly as it did.
    final now = DateTime.now();
    final upTo = (sentAt == null || sentAt.isAfter(now)) ? now : sentAt;
    await messages.clearForChatUpTo(canonical, upTo);
    if (canonical != peerId) await messages.clearForChatUpTo(peerId, upTo);
    DebugLog.instance.log(
      'CHAT',
      '$canonical cleared the conversation here (up to $upTo)',
    );
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

    // Play it out rather than snap it away. This is the deletion nobody asked
    // for and the one most likely to be watched happening, so a row that
    // simply ceases to exist between two frames reads as the app losing a
    // message rather than as the sender withdrawing it.
    //
    // The wire carries a hash, not a local id, so the row has to be found
    // before it can be marked; if it is not here, there is nothing to animate
    // and the delete still runs.
    void remove() {
      messages.deleteFromPeer(canonical, target);
      if (canonical != peerId) messages.deleteFromPeer(peerId, target);
    }

    final stored = _ref.read(messagesControllerProvider);
    final localId = [
      ...?stored[canonical],
      if (canonical != peerId) ...?stored[peerId],
    ].where((m) => m.wireId == target).map((m) => m.id).toSet();

    unawaited(
      _ref
          .read(messageFarewellProvider(canonical).notifier)
          .dismiss(localId, remove),
    );
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

  Future<void> _ensureCanPostToChannel(Channel channel) async {
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
    if (channel.adminOnly && !roster.isAdmin(channel.name, me.id)) {
      throw StateError('only admins can write to ${channel.name}');
    }
  }

  /// Copy a post into the room where it is discussed.
  ///
  /// Only for an announcement channel, and only from the side that posted it.
  /// A room where anyone may write already *is* its own discussion; it is the
  /// one-way channel that needs somewhere for the reply to go, which is the
  /// whole reason Telegram grew a linked group.
  ///
  /// The copy is an ordinary message in an ordinary room, so what a reader
  /// finds there is the post followed by whatever was said about it, in the
  /// order it was said — which is what "comments under the post" comes to when
  /// nothing anywhere is keeping a thread. No new payload, no thread ids, and
  /// an old build in the same room sees a plain group chat.
  ///
  /// Best effort, deliberately. A post that reached the channel is delivered;
  /// failing to echo it into the discussion must not report the post as failed,
  /// so nobody awaits this and it swallows its own errors.
  Future<void> _mirrorToCommunity(Channel channel, String text) async {
    // The discussion room is itself a channel, and posting into it comes back
    // through here. Without this the first comment would echo into
    // `#news-chat-chat` and keep going.
    if (channelForCommunity(channel.name) != null) return;
    if (!channel.adminOnly) return;
    try {
      final channels = _ref.read(channelControllerProvider.notifier);
      final community = await channels.joinCommunity(
        channel.name,
        // We are posting to an admin-only room, so we are one of its admins —
        // [_ensureCanPostToChannel] established that before we got here.
        asAdmin: true,
      );
      if (community == null) return;
      await sendChannelText(community.name, text);
    } catch (e) {
      debugPrint('mirror to community failed: $e');
    }
  }

  /// Post [text] to a joined channel. Encrypted under the shared channel key
  /// and broadcast across the mesh; every member with the key decrypts it.
  /// Returns the local pending Message (bucketed under the channel name).
  /// [replyToWireId] threads this under an earlier message.
  ///
  /// What makes a comment a comment. A discussion room is otherwise a flat
  /// conversation, and "the comments on this post" is only answerable if each
  /// one says which post it belongs to — the reply target is that, and the
  /// channel ingest has understood it for as long as rooms have shown quotes.
  /// Only the composing side was missing.
  Future<Message> sendChannelText(
    String channelName,
    String text, {
    String? replyToWireId,
    String? replyPreview,
  }) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) {
      throw StateError('not a member of $channelName');
    }
    await _ensureCanPostToChannel(channel);
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
      replyToWireId: replyToWireId,
      replyPreview: replyPreview,
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);

    try {
      final utf8Text = Uint8List.fromList(utf8.encode(text));
      final inner = padTextPayload(utf8Text);
      // A malformed handle is ignored rather than failing the send, the same
      // way the 1:1 path treats one: losing the thread is better than losing
      // the message.
      Uint8List? replyTarget;
      if (replyToWireId != null) {
        try {
          final decoded = _hexDecodeBytes(replyToWireId);
          if (decoded.length == replyTargetLen) replyTarget = decoded;
        } catch (_) {}
      }
      final frame = replyTarget == null
          ? await _buildChannelFrame(
              channel, InnerPayloadType.text, inner, msgId)
          : await _buildChannelFrame(
              channel,
              InnerPayloadType.textReply,
              packTextReply(replyTarget, inner),
              msgId,
            );
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
      unawaited(_mirrorToCommunity(channel, text));
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
  /// [reuseImageId] re-sends a picture the room has already seen, under the id
  /// it originally travelled with.
  ///
  /// That id is the whole mechanism: a message's wireId is its hash, insertion
  /// is idempotent on the wireId, so a replay lands only on a phone that does
  /// not have the picture — which is exactly the new member the history offer
  /// exists for. Minting a fresh id instead would show the room its own
  /// photographs a second time.
  ///
  /// A replay writes nothing locally and returns null: the bubble is already
  /// here, and appending it again is the duplicate this is designed to avoid.
  Future<Message?> sendChannelImage(
    String channelName, {
    required Uint8List bytes,
    required String mime,
    String? cachedPath,
    String? caption,
    Uint8List? reuseImageId,
  }) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    await _ensureCanPostToChannel(channel);

    final replay = reuseImageId != null;
    final imageId = reuseImageId ?? ImageChunk.newImageId();
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
      mediaId: _hexOf(imageId),
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    if (!replay) messages.append(channel.name, msg);

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
      DebugLog.instance.log(
        'CHAN',
        '${replay ? 'replayed' : 'channel'} photo to ${channel.name}: '
            '$total chunks, fanout=$fanout',
      );
      // Nothing to mark on a replay: there is no pending bubble here, only a
      // picture already in the history being offered again.
      if (replay) return null;
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
      if (!replay) {
        messages.updateStatus(channel.name, msg.id, MessageStatus.failed);
      }
      rethrow;
    }
    return msg;
  }

  /// A voice note to a room.
  ///
  /// The same shape as [sendChannelImage] — manifest, then chunks, over the
  /// signed channel frame — because a room's media has no addressee and so none
  /// of the 1:1 path's per-recipient machinery applies: no peer pubkey, no
  /// X3DH, no store-and-forward for one person. Rooms could already carry
  /// photos and polls; audio was simply never wired, so the recorder came up in
  /// a channel and had nowhere to send what it recorded.
  Future<Message> sendChannelAudio(
    String channelName, {
    required Uint8List bytes,
    required String mime,
    required int durationMs,
    String? cachedPath,
  }) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    await _ensureCanPostToChannel(channel);

    final audioId = AudioChunk.newAudioId();
    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: channel.name,
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
    messages.append(channel.name, msg);

    try {
      final relayOnly = !_hasAnyLink;
      final chunkData = _mediaChunkData(null,
          relayOnly: relayOnly, ceiling: AudioChunk.maxDataBytes);
      final total = (bytes.length + chunkData - 1) ~/ chunkData;
      if (total < 1 || total > AudioChunk.maxChunks) {
        throw StateError(
          'audio too large: $total chunks > ${AudioChunk.maxChunks} cap',
        );
      }
      final sha = Uint8List.fromList((await Sha256().hash(bytes)).bytes);
      final manifest = MediaManifest(
        mediaId: audioId,
        kind: MediaKind.audio,
        total: total,
        mime: mime,
        durationMs: durationMs,
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
        final chunk = AudioChunk(
          audioId: audioId,
          seq: i,
          total: total,
          durationMs: durationMs,
          mime: mime,
          data: Uint8List.fromList(bytes.sublist(start, end)),
        );
        fanout = await _broadcastChannelFrame(
          await _buildChannelFrame(
            channel,
            InnerPayloadType.audioChunk,
            chunk.encode(),
            TransportEnvelope.newMsgId(initialTtl: _meshTtl),
          ),
        );
        // Same pacing as the channel photo path.
        if (i + 1 < total && !relayOnly) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
      }
      DebugLog.instance.log('CHAN',
          'channel voice to ${channel.name}: $total chunks, fanout=$fanout');
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
      debugPrint('sendChannelAudio failed: $e\n$st');
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
    // [ensureSelf] above has just claimed the seat if it was going spare, so
    // by here a room genuinely has an owner and this is a real check again.
    // (It was briefly relaxed to "unowned means everyone", which read to
    // testers as the admin rule doing nothing at all — because for them it
    // didn't.)
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
    // Bigger than one broadcast frame goes the way a photo posted to the room
    // goes: a signed manifest, then chunks. The room's picture used to be
    // whatever survived being squeezed into a single unsplittable frame, which
    // is a fact about the BLE fragmenter rather than about a picture.
    if (jpeg != null && jpeg.length > AvatarPayload.maxBytes) {
      await _sendChannelAvatarChunked(channel, jpeg);
      return;
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

  /// A room's picture as a manifest and chunks.
  ///
  /// The same machinery [sendChannelImage] uses, with the manifest's kind
  /// saying where the finished bytes belong — so nothing here needed inventing
  /// except somewhere to put the result. Sized for the conservative MTU, like
  /// every broadcast: there is no single link to negotiate against.
  Future<void> _sendChannelAvatarChunked(Channel channel, Uint8List jpeg) async {
    const mime = 'image/jpeg';
    final avatarId = ImageChunk.newImageId();
    final relayOnly = !_hasAnyLink;
    final chunkData = _mediaChunkData(null,
        relayOnly: relayOnly, ceiling: ImageChunk.maxDataBytes);
    final total = (jpeg.length + chunkData - 1) ~/ chunkData;
    if (total < 1 || total > ImageChunk.maxChunks) {
      throw StateError('picture is too large for ${channel.name}');
    }
    final manifest = MediaManifest(
      mediaId: avatarId,
      kind: MediaKind.avatar,
      total: total,
      mime: mime,
      durationMs: 0,
      sha256: Uint8List.fromList((await Sha256().hash(jpeg)).bytes),
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
      final end = (start + chunkData).clamp(0, jpeg.length);
      fanout = await _broadcastChannelFrame(
        await _buildChannelFrame(
          channel,
          InnerPayloadType.imageChunk,
          ImageChunk(
            imageId: avatarId,
            seq: i,
            total: total,
            mime: mime,
            data: Uint8List.fromList(jpeg.sublist(start, end)),
          ).encode(),
          TransportEnvelope.newMsgId(initialTtl: _meshTtl),
        ),
      );
      if (i + 1 < total && !relayOnly) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    }
    DebugLog.instance.log(
      'CHAN',
      'channel picture for ${channel.name}: ${jpeg.length}B in $total chunks, '
          'fanout=$fanout',
    );
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
    // A real check again, exactly as for the picture above.
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
    await _ensureCanPostToChannel(channel);

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
  /// Tell the room that this phone holds the admin seat.
  ///
  /// A room has no creation event: the seat is claimed locally by the first
  /// member who did not arrive by invitation, and until now that claim never
  /// left the phone that made it. Every rule enforced against "is this person
  /// an admin" therefore ran against an answer nobody else had.
  ///
  /// Best-effort and quiet: a room where somebody else is already known to be
  /// the admin refuses this on arrival, which is the correct outcome and not
  /// worth a word to the user.
  /// Say who runs this room, once per room per run.
  ///
  /// The claim used to go out only when somebody turned the announcement rule
  /// on — so a room that was *already* admin-only never said it again, and two
  /// phones that had each granted themselves the seat (which is what an empty
  /// roster does to everybody who joins by typing the name) stayed that way
  /// forever. Both could post, so no reader ever saw a reader's bar, and each
  /// refused the other's backlog because the sender was not an administrator as
  /// far as their roster knew.
  ///
  /// Saying it on the way into the room is what lets the two converge — see the
  /// `channelAdmin` ingest, which settles two guesses by fingerprint. Once per
  /// run, because it is a fact that does not change and the room pays for every
  /// broadcast.
  final Set<String> _seatAnnounced = {};

  Future<void> announceChannelSeat(String channelName) async {
    if (!_seatAnnounced.add(channelName)) return;
    await _announceOwnAdminSeat(channelName);
  }

  Future<void> _announceOwnAdminSeat(String channelName) async {
    try {
      final channel =
          _ref.read(channelControllerProvider.notifier).byName(channelName);
      if (channel == null) return;
      final roster = _ref.read(channelRosterControllerProvider.notifier);
      final me = await roster.ensureSelf(channel.name, adminWhenFirst: true);
      if (!roster.isAdmin(channel.name, me.id)) return;
      final frame = await _buildChannelFrame(
        channel,
        InnerPayloadType.channelAdmin,
        ChannelAdminChange(memberId: me.id, isAdmin: true).encode(),
        TransportEnvelope.newMsgId(initialTtl: _meshTtl),
      );
      await _broadcastChannelFrame(frame);
    } catch (e) {
      DebugLog.instance.log('CHAN', 'admin seat announce failed: $e');
    }
  }

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

    // No `wakesPeer` on this path or the one below, and that is the fix rather
    // than an omission. Everything that travels as a control frame is
    // machinery — the presence heartbeat every 70 seconds, typing notices,
    // read receipts, copy-restriction notes, the conversation clear — and none
    // of it is news to a person. Waking a closed phone for all of it put a
    // "New message" banner on the lock screen about once a minute with no
    // message behind it, which teaches the owner to ignore the real ones.
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
    // Same internet fallback as sendText: a receipt or reaction the mesh can't
    // deliver still reaches a peer who's only on relays.
    //
    // The relay is tried even when the fan-out found links, unless one of them
    // is a session with this peer. A fan-out onto somebody else's Bluetooth
    // link is a *hope* that the mesh knows a route; for a peer we only ever
    // reach over the internet it is a dead end — and counting it as delivery
    // marked the receipt acknowledged, so it was never retried and the sender's
    // tick never turned over. That is exactly the shape of "read receipts stop
    // working over the internet as soon as any phone is nearby". Duplicates are
    // free: both copies carry the same msgId, and the receiver dedups.
    final direct = transportId != null;
    if (fanout > 0 && direct) return fanout;
    final viaRelay = await _sendOverNostr(canonicalId, frameBytes) ? 1 : 0;
    return fanout + viaRelay;
  }

  /// Build a broadcast channel frame: sign the inner payload (full signature,
  /// so members learn the author's Ed25519 key), encrypt it under the channel
  /// key, prepend the public channel tag + cipher tag, and wrap in a
  /// broadcast [TransportEnvelope]. Pre-records the msgId in the dedup cache
  /// so our own copy bouncing back over a relay is ignored.
  /// Close a room for everybody in it. Owner only.
  ///
  /// Sent first and wiped second, in that order: the frame is built from the
  /// channel's key, and forgetting the key before broadcasting would leave
  /// nothing to sign with — the room would go from this phone and stay on
  /// every other one, which is the worst of both.
  ///
  /// What this can do and what it cannot: the key is derived from the name, so
  /// nobody is locked out and anyone who remembers the name can type it again
  /// into an empty room. What it does is take the room off every phone that
  /// has it. That is what deleting a group means to the person asking, and it
  /// is achievable here; "nobody can ever come back" is not, and the interface
  /// says so.
  Future<void> sendChannelDeleteForEveryone(String channelName) async {
    final channel =
        _ref.read(channelControllerProvider.notifier).byName(channelName);
    if (channel == null) throw StateError('not a member of $channelName');
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final me = await roster.selfMemberId();
    if (!roster.isOwner(channel.name, me)) {
      throw StateError('only the owner can close $channelName');
    }
    final frame = await _buildChannelFrame(
      channel,
      InnerPayloadType.channelDelete,
      ChannelDelete(channelName: channel.name).encode(),
      TransportEnvelope.newMsgId(initialTtl: _meshTtl),
    );
    await _broadcastChannelFrame(frame);
    DebugLog.instance.log('CHAN', 'closed ${channel.name} for everyone');
    await wipeChannelLocally(channel.name);
  }

  /// Forget a room: its key, its messages, its roster, its picture, its topic.
  ///
  /// Public because both ends need it — the owner after broadcasting, and
  /// every member on receiving. Deliberately not the chat-list's own delete,
  /// which is a UI function holding a container and asking questions; this is
  /// the same sequence from the transport's side, and it asks nothing because
  /// the decision was made by somebody with the authority to make it.
  Future<void> wipeChannelLocally(String name) async {
    await _ref.read(messagesControllerProvider.notifier).clearForChat(name);
    await _ref.read(pinnedControllerProvider.notifier).forget(name);
    await _ref.read(readMarkersControllerProvider.notifier).forget(name);
    await _ref.read(channelRosterControllerProvider.notifier).forget(name);
    await _ref.read(channelDescriptionsControllerProvider.notifier).forget(name);
    await _ref.read(channelAvatarsControllerProvider.notifier).forget(name);
    // Last, because everything above is keyed on the room still being one.
    await _ref.read(channelControllerProvider.notifier).leave(name);
    DebugLog.instance.log('CHAN', 'wiped $name locally');
  }

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
    _rememberChannelFrame(frameBytes);
    final mesh = await _fanoutAllLinks(frameBytes, excludePeerId: null);
    final relayed = await _broadcastChannelOverNostr(frameBytes);
    return mesh + relayed;
  }

  /// The last few room frames, kept to hand to a neighbour who arrives after
  /// they were sent.
  ///
  /// A room frame is addressed to nobody, so store-and-forward — which files
  /// mail by destination — has nothing to file it under, and the mesh fan-out
  /// reaches exactly the links that happen to be up at that instant. Over
  /// Bluetooth that is the whole problem: post something with nobody
  /// connected, or with the other phone thirty seconds from walking into
  /// range, and it is simply gone. Nothing re-sends it, because a broadcast
  /// has no acknowledgement to be missing.
  ///
  /// Small and short-lived on purpose. This is a catch-up for the last few
  /// minutes of a conversation, not history sync: the relay path already
  /// carries the room for anybody with internet, and a phone that has been
  /// away for an hour is not going to be caught up by its neighbour's memory.
  /// Pictures are left out — a 35 KB avatar handed to every link that comes up
  /// is a lot of Bluetooth for something the room can live without.
  final _recentChannelFrames = <_RecentChannelFrame>[];

  static const Duration _channelReplayWindow = Duration(minutes: 20);
  static const int _channelReplayCap = 40;
  static const int _channelReplayMaxBytes = 4 * 1024;

  void _rememberChannelFrame(Uint8List frameBytes) {
    if (frameBytes.length > _channelReplayMaxBytes) return;
    final now = DateTime.now();
    _recentChannelFrames
      ..removeWhere((f) => now.difference(f.at) > _channelReplayWindow)
      ..add(_RecentChannelFrame(bytes: frameBytes, at: now));
    if (_recentChannelFrames.length > _channelReplayCap) {
      _recentChannelFrames.removeAt(0);
    }
  }

  /// Hand a freshly-connected neighbour the room traffic they just missed.
  ///
  /// Duplicates are free: every frame carries its origin and message id, and
  /// the receiving side has always dropped a repeat of a pair it has seen.
  Future<void> _replayChannelFramesTo(ChatSession session) async {
    final now = DateTime.now();
    _recentChannelFrames
        .removeWhere((f) => now.difference(f.at) > _channelReplayWindow);
    if (_recentChannelFrames.isEmpty) return;
    final frames =
        _recentChannelFrames.map((f) => f.bytes).toList(growable: false);
    DebugLog.instance.log('CHAN',
        'catching ${session.peerId} up on ${frames.length} room frame(s)');
    final client = _clients[session.peerId];
    for (final bytes in frames) {
      try {
        if (client != null && client.isConnected) {
          await _writeFrameToClient(client, bytes);
        } else {
          await _notifyFrameToPeripheral(bytes);
        }
      } catch (e) {
        DebugLog.instance.log('CHAN', 'room catch-up failed: $e');
        return;
      }
      // Paced like every other chunked send, so a cheap stack is not asked to
      // swallow forty frames at once.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
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
        if (await _sendOverNostr(
          targets[i].pubkeyHex,
          frameBytes,
          wakesPeer: true,
        )) {
          sent++;
        }
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
    // Worth carrying, not just passing on. We are in this room, so the frame
    // that just reached us is the frame the next neighbour to walk up is
    // missing — and their link may not exist for another ten minutes. The
    // mesh's own relay only reaches the links that are up right now.
    _rememberChannelFrame(bytes);
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
    // Past the replay window, and when the author says they wrote it. See
    // [_pastReplayWindow]: a post is a stored message and survives being old;
    // the room's control frames do not.
    bool channelStale;
    DateTime channelSignedAt;
    try {
      final expectedEd = await _expectedEdPubFor(env.originPubkeyHash);
      final verified = await SignedPayload.verify(
        wire: plain,
        context: ctx,
        expectedEdPub: expectedEd,
      );
      if (!_plausibleClock(verified.timestampMs, peerId)) return;
      channelStale = _pastReplayWindow(verified.timestampMs, peerId);
      channelSignedAt =
          DateTime.fromMillisecondsSinceEpoch(verified.timestampMs);
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
      if (channelStale && !survivesReplayWindow(unpacked.type)) return;
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

      // An announcement room: content from a non-admin is dropped.
      //
      // This is the enforcement that counts, and the only one available. The
      // channel key is shared, so every member can always encrypt a frame —
      // refusing to send is politeness, not a control. What makes the rule real
      // is here: the frame is signed, the signature has already been verified
      // above, and a reader simply does not accept a post from somebody their
      // own roster does not have as an admin.
      //
      // Control frames are exempt and handled below on their own admin checks:
      // an admin change, the picture, the topic and the copy rule each decide
      // for themselves, and a reaction or a read receipt is not a post.
      // Held rather than dropped, for the same reason the room's picture is:
      // a roster is learned from the room over time, and a member who has not
      // yet been told who the admin is would otherwise refuse that admin's
      // own posts — permanently, since nothing is ever sent twice. Once the
      // roster names them, the post is delivered.
      // Put out of the room, or silenced for a while.
      //
      // Ahead of the announcement rule and applying to every room, because it
      // is about a person rather than about who may speak here. Posts only:
      // an administrator's own frames still have to reach us, and a receipt or
      // a reaction from somebody silenced is not what anybody meant by muting
      // them.
      if (_isChannelPost(unpacked.type) &&
          !_ref
              .read(channelRosterControllerProvider.notifier)
              .canPost(channel.name, reactorId)) {
        DebugLog.instance.log(
          'CHAN',
          'drop ${channel.name} post: $reactorId is removed or muted',
        );
        return;
      }

      // A backlog waits for the same answer a post waits for.
      //
      // It used to be dropped outright instead of held, which is most of why
      // "the history does not arrive": the offer and the seat announcement that
      // authorises it are two broadcasts, and there is no order in which one is
      // guaranteed to land first. Dropped, the offer was gone; held, it is
      // handed back through this same path the moment the roster learns who
      // sent it, and the check below is re-run then.
      final needsAnAdmin = _isChannelPost(unpacked.type) ||
          unpacked.type == InnerPayloadType.channelHistory;
      if (channel.adminOnly &&
          needsAnAdmin &&
          !_ref
              .read(channelRosterControllerProvider.notifier)
              .isAdmin(channel.name, reactorId)) {
        DebugLog.instance.log('CHAN',
            'hold ${channel.name} post: $reactorId is not a known admin yet');
        // Held as the frame it arrived as, and simply handed back through
        // this same path once the roster has learned who the admin is — the
        // check is re-run then, so nothing is let through that would not be
        // let through now.
        _holdChannelPost(
          channelName: channel.name,
          senderId: reactorId,
          deliver: () => _handleChannelBody(
            env: env,
            peerId: peerId,
            channelBody: channelBody,
          ),
        );
        return;
      }

      switch (unpacked.type) {
        case InnerPayloadType.text:
          final plaintext = utf8.decode(
            unpadTextPayload(unpacked.body),
            allowMalformed: true,
          );
          final arrivedAt = DateTime.now();
          final beacon = SharedLocation.tryParse(plaintext);
          if (beacon != null &&
              SharedLocation.isBeaconText(plaintext, arrivedAt)) {
            _ref.read(mapPresenceStoreProvider.notifier).record(
                  reactorId,
                  beacon,
                  sentAt: arrivedAt,
                );
            return;
          }
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
          // The local privacy switch controls what this device sends. If a
          // channel member chooses to send a receipt, applying it only updates
          // ticks on our own messages.
          _ingestChannelReceipt(
            channel: channel,
            readerId: reactorId,
            readerName: authorName,
            body: unpacked.body,
          );

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
        case InnerPayloadType.channelDelete:
          final ask = ChannelDelete.decode(unpacked.body);
          final roster = _ref.read(channelRosterControllerProvider.notifier);
          // The name inside the signed body has to be the room the frame
          // arrived in. The signature covers the body, so this is what stops a
          // delete lifted from one room being replayed into another — and for
          // an instruction with no undo that check is worth two bytes.
          if (normalizeChannelName(ask.channelName) != channel.name) {
            DebugLog.instance.log(
              'CHAN',
              'drop close: signed for ${ask.channelName}, arrived in '
                  '${channel.name}',
            );
            break;
          }
          final owner = roster.ownerOf(channel.name);
          // No owner recorded, no delete. Deliberately not "fall back to any
          // administrator": a room that predates ownership has nobody it can
          // name, and the safe reading of an irreversible instruction from an
          // unidentified sender is to ignore it.
          if (owner == null || owner != reactorId) {
            DebugLog.instance.log(
              'CHAN',
              'drop close of ${channel.name}: $reactorId is not the owner '
                  '(${owner ?? "none recorded"})',
            );
            break;
          }
          DebugLog.instance
              .log('CHAN', '${channel.name} closed by its owner — wiping');
          await wipeChannelLocally(channel.name);
          return;

        case InnerPayloadType.channelAdmin:
          final change = ChannelAdminChange.decode(unpacked.body);
          final roster = _ref.read(channelRosterControllerProvider.notifier);
          // Somebody saying they are the admin of a room that has none.
          //
          // Without this a room's admin is a fact only their own phone holds.
          // Appointing anybody is itself an admin action, so a member accepts
          // an admin change only from somebody they *already* have as an
          // admin — and nothing ever told them who the first one was. Turn on
          // "only admins may post" in that state and every member drops every
          // post, including the admin's own, which is what a log of three
          // phones shows: `drop #room post: … is not an admin`, over and over,
          // in a room somebody was talking in.
          //
          // Accepted on the same terms this phone claims the seat for itself
          // — see ChannelRosterController.ensureSelf: the room is unowned, so
          // the first claim wins. It is trust on first use rather than proof,
          // which is all a shared key can offer, and a claim on a room that
          // already has an admin is refused below as it always was.
          final claimsSelf = change.memberId == reactorId && change.isAdmin;
          if (roster.isAdmin(channel.name, reactorId)) {
            await roster.setAdmin(
              channel.name,
              change.memberId,
              change.isAdmin,
            );
          } else if (claimsSelf && !roster.hasConfirmedAdmin(channel.name)) {
            // Two phones that each typed the room's name, each finding an
            // empty roster, each handing themselves the seat — and then each
            // refusing the other, because a claim used to be accepted only on
            // a room with nobody in it. Both were administrators of the same
            // channel and neither ever saw a reader's view of one.
            //
            // Nobody here holds the room on more than their own say-so, so the
            // two guesses are settled by the one thing both phones can compute
            // without talking: the lower fingerprint takes it. Same answer on
            // both, whichever claim arrives first.
            final mine = await roster.selfMemberId();
            final weGuessedToo = roster.holdsProvisionalSeat(channel.name, mine);
            if (weGuessedToo && mine.compareTo(reactorId) < 0) {
              // Ours by the tie-break. Say so once, so they can stand down —
              // once, because two phones re-announcing at each other is how a
              // room fills the air with nothing.
              if (_seatDefended.add('${channel.name}/$reactorId')) {
                unawaited(_announceOwnAdminSeat(channel.name));
              }
            } else {
              await roster.setAdmin(channel.name, change.memberId, true);
              if (weGuessedToo) {
                // Theirs, so ours goes. This is the line that turns a phone
                // back into a reader — the composer becomes the reader's bar,
                // and posts start being accepted from the person who actually
                // runs the room.
                await roster.setAdmin(channel.name, mine, false);
                DebugLog.instance.log(
                  'CHAN',
                  '${channel.name}: stood down, $reactorId holds the room',
                );
              }
            }
          }

        case InnerPayloadType.channelModeration:
          final call = ChannelModeration.decode(unpacked.body);
          final roster = _ref.read(channelRosterControllerProvider.notifier);
          // Only from somebody this device already holds as an administrator.
          // The frame is signed, so this is not about who sent it but about
          // whether they were entitled to — and an unowned room grants nothing,
          // unlike the admin claim above, because removing people is not how
          // anybody should come into a seat.
          if (!roster.isAdmin(channel.name, reactorId)) {
            DebugLog.instance.log(
              'CHAN',
              'drop ${channel.name} moderation: $reactorId is not an admin',
            );
            return;
          }
          // An administrator cannot be removed or silenced by another one.
          // Seniority is not a thing this protocol can establish, so the only
          // safe rule is that the seat protects its holder — otherwise two
          // admins can take turns removing each other and the room ends up
          // with a different answer on every phone.
          if (roster.isAdmin(channel.name, call.memberId)) {
            DebugLog.instance.log(
              'CHAN',
              'drop ${channel.name} moderation: target is an admin',
            );
            return;
          }
          await roster.moderate(
            channel.name,
            memberId: call.memberId,
            removed: call.action == ChannelModerationAction.remove,
            mutedUntil:
                call.action == ChannelModerationAction.mute ? call.until : null,
            clear: call.action == ChannelModerationAction.clear,
          );
          DebugLog.instance.log(
            'CHAN',
            '${channel.name}: ${call.memberId} ${call.action.name}',
          );

        case InnerPayloadType.channelHistory:
          await _ingestChannelHistory(
            channel: channel,
            senderId: reactorId,
            body: unpacked.body,
          );

        case InnerPayloadType.forwardPrivacy:
          // A statement about a person, made to the people they talk to. It
          // has no meaning shouted at a room, and accepting it there would let
          // anybody holding the key speak for anybody else.
          break;

        case InnerPayloadType.channelAvatar:
        case InnerPayloadType.channelAdminOnly:
        case InnerPayloadType.copyRestriction:
        case InnerPayloadType.channelDescription:
        case InnerPayloadType.conversationWallpaper:
          await _applyOrHoldChannelState(
            channelName: channel.name,
            type: unpacked.type,
            senderId: reactorId,
            body: unpacked.body,
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
            sentAt: _stampFrom(channelSignedAt),
          );

        case InnerPayloadType.imageChunk:
          await _ingestImageChunk(
            peerId: channel.name,
            senderPub: null,
            chunkBytes: unpacked.body,
          );

        case InnerPayloadType.audioChunk:
          // Reassembled under the room's name, exactly as a channel photo is:
          // the frame carried no addressee and its signature was already
          // checked, so there is no per-sender key to thread through here.
          await _ingestAudioChunk(
            peerId: channel.name,
            senderPub: null,
            chunkBytes: unpacked.body,
          );

        case InnerPayloadType.channelInvite:
        case InnerPayloadType.fileChunk:
        case InnerPayloadType.presence:
        case InnerPayloadType.avatarRequest:
        case InnerPayloadType.avatar:
        case InnerPayloadType.mediaRequest:
        case InnerPayloadType.viewOnceConsumed:
        case InnerPayloadType.typing:
        case InnerPayloadType.albumHint:
        case InnerPayloadType.voiceLevels:
        case InnerPayloadType.forwardedFrom:
        case InnerPayloadType.conversationClear:
        case InnerPayloadType.callSignal:
          // Not carried in channels — ignore. (An invite is addressed to one
          // peer; broadcasting one to the channel would be circular, presence
          // is per-peer, an avatar answers a request from one peer — a
          // channel-wide broadcast of a picture is a fan-out nobody asked for,
          // and a request for a file again has no single member to answer it.)
          //
          // copyRestriction used to sit in this list, on the reasoning that one
          // member cannot decide for a room what everyone else may keep. That
          // is true of a member and false of the room's admin, who decides its
          // picture and its topic already — so it is handled above instead.
          //
          // callSignal joins the list for the same reason as an invite: calls
          // are 1:1 in this first version (see the design spec), so a signal
          // arriving inside a channel frame names no call anyone could answer.
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
    var outcome = messages.markRead(canonical, ids);
    if (canonical != peerId) outcome += messages.markRead(peerId, ids);
    // Said out loud, because "the tick never turns blue" has no other evidence
    // to work from: the frame arriving and the frame *meaning* something are
    // different failures, and only this line tells them apart.
    //
    // Split three ways, because two of them used to look identical and one of
    // those is not a fault at all. "2 id(s), 1 marked" cost an investigation
    // on the assumption that a handle had gone missing; the far likelier
    // reading is the same receipt arriving again from a second relay and
    // finding the message already read, which is the mechanism working. Only
    // `unknown` — an id matching nothing we ever sent — is worth chasing, and
    // it now says so in that word.
    DebugLog.instance.log(
      'RECEIPT',
      'read ack from ${_short(canonical)}: ${ids.length} id(s), '
      '${outcome.marked} marked'
      '${outcome.alreadyRead > 0 ? ', ${outcome.alreadyRead} already read' : ''}'
      '${outcome.unknown > 0 ? ', ${outcome.unknown} UNKNOWN' : ''}',
    );
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
      body: '$authorName: ${messagePreview(message, _localizations)}',
      senderId: channel.name,
      isGroup: true,
    ));
  }

  /// The first eight characters of a chat id, which is how every other line
  /// in the log names a peer.
  static String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

  /// The app's strings, in the language it is set to.
  ///
  /// A notification is composed outside the widget tree, so there is no
  /// context to look these up from — and the lines it used to build were
  /// English constants regardless of what the user had chosen.
  AppLocalizations get _localizations =>
      lookupAppLocalizations(_ref.read(localeControllerProvider));

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
    DateTime? sentAt,
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
        await _handleInboundBytes(
          peerId,
          whole,
          fromCentral: fromCentral,
          sentAt: sentAt,
        );
      }
      return;
    }
    await _handleFrame(peerId, frame, fromCentral: fromCentral, sentAt: sentAt);
  }

  Future<void> _handleFrame(
    String peerId,
    Frame frame, {
    required bool fromCentral,
    /// When the sender stamped this, for the payloads that are a claim about a
    /// moment. Null on a radio link, where arrival *is* the moment: a
    /// Bluetooth frame was written to the air by somebody in range, seconds
    /// ago. Only the relay can hand over something written hours before.
    DateTime? sentAt,
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
        await _handleTransportFrame(peerId, frame, sentAt: sentAt);

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
  Future<void> _handleTransportFrame(
    String peerId,
    Frame frame, {
    /// When the sender stamped it — see [_handleFrame]. Only the payloads
    /// that are a claim about a moment look at this.
    DateTime? sentAt,

    /// A second pass at a frame this phone held because it could not yet
    /// verify who sent it — see [_holdUnverified]. It has already been through
    /// the duplicate check once and must not be refused by it now.
    bool replaying = false,
  }) async {
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
    if (!replaying && !_dedup.acceptEnvelope(env)) {
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
        // One line a second, not one a frame. Relaying for a busy neighbour is
        // a hundred frames a second, and at 200 lines of ring buffer that was
        // the whole log — the same failure the BLE fragment meter exists for.
        final now = DateTime.now();
        if (_lastHoldLogAt == null ||
            now.difference(_lastHoldLogAt!) >= const Duration(seconds: 1)) {
          _lastHoldLogAt = now;
          DebugLog.instance.log(
              'MESH',
              'holding for peers out of range '
                  '(${_store.size} frame(s) across ${_store.destinationCount} dest)');
        }
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
          _evictPendingFsOverBudget();
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
      // When the sender says they sent it, in their own signature.
      //
      // Every received message used to be stamped `DateTime.now()` — the
      // moment its last byte landed. Over a relay that is whenever the phone
      // next connected, so a conversation reopened after a while showed
      // yesterday's messages as having arrived at breakfast, all at the same
      // minute; over Bluetooth it is when the transfer finished, which for a
      // photo is minutes after it was sent. Nothing on the receiving side knew
      // any better, and the file said so in several places.
      //
      // It did know. The signature covers a timestamp — it is what the replay
      // window has always been reading — and a relay cannot alter it without
      // the sender's Ed25519 key. So the clock was on the wire the whole time,
      // used only to reject things.
      //
      // Clamped to now on use, never trusted forward: see [_stampFrom].
      DateTime? signedAt;
      // Older than the replay window. Not a verdict by itself any more — the
      // payload type decides. See [_pastReplayWindow].
      var stale = false;
      if (sealedPlain.isNotEmpty &&
          sealedPlain[0] == SignedPayload.markerByte) {
        try {
          final expectedEd = await _expectedEdPubFor(env.originPubkeyHash);
          final verified = await SignedPayload.verify(
            wire: sealedPlain,
            context: ctx,
            expectedEdPub: expectedEd,
          );
          if (!_plausibleClock(verified.timestampMs, peerId)) return;
          stale = _pastReplayWindow(verified.timestampMs, peerId);
          signedAt =
              DateTime.fromMillisecondsSinceEpoch(verified.timestampMs);
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
          // Held, not dropped, and that is the whole of this change.
          //
          // A compact signature carries no ed pub, so the sender's verifying
          // key has to be known already. It usually is — but a message and the
          // announcement identifying its sender are separate frames on
          // separate paths, and either can arrive first. This one lost the
          // race, and losing it used to mean the message was gone for good.
          //
          // Invisible from the inside and loud from the outside: the push
          // service rings on seeing an event addressed to you and decrypts
          // nothing, so the banner arrived and the app opened on an empty
          // chat. Reported in those words, and the log agreed — one
          // `drop FS body … awaiting their announcement` per lost message,
          // several an hour in ordinary use.
          //
          // Channels already had this shape for the same reason: a post can
          // beat the roster that says its author may speak. See
          // [_replayHeldChannelPosts].
          _holdUnverified(env.originPubkeyHash, peerId, frame, sentAt);
          return;
        }
        try {
          final verified = await SignedPayload.verifyCompact(
            wire: sealedPlain,
            context: ctx,
            expectedEdPub: expectedEd,
          );
          if (!_plausibleClock(verified.timestampMs, peerId)) return;
          stale = _pastReplayWindow(verified.timestampMs, peerId);
          signedAt =
              DateTime.fromMillisecondsSinceEpoch(verified.timestampMs);
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

      // Who this frame claims to be from, according to the envelope alone.
      //
      // A claim, not a fact — the origin hash is a plaintext field anybody can
      // write. It becomes a fact in exactly one way: a valid signature, whose
      // context covers this hash (see [SignedPayload.contextBytes]), so a
      // signer cannot be made to vouch for an origin they did not send from.
      final claimedPub = await _canonicalPubForOrigin(env.originPubkeyHash);

      // The signer first, the link second.
      //
      // It used to be the other way round, which was right when a Noise link
      // was the only way in: the peer at the other end of it is authenticated
      // by the handshake, so it was the better answer. It stopped being the
      // better answer once frames could arrive having been relayed — over the
      // mesh a neighbour hands us somebody else's frame, and taking the sender
      // from the link files it under the neighbour.
      final senderPub = (verifiedSenderEdPub != null
              ? await _canonicalPubForVerifiedSender(
                  originPubkeyHash: env.originPubkeyHash,
                  senderEdPub: verifiedSenderEdPub,
                )
              : null) ??
          session?.remoteStaticPublicKey;

      // Unsigned bodies are accepted from exactly two places, and this is the
      // fence around them.
      //
      // A SealedBox proves nothing about who sealed it: anyone holding the
      // recipient's public key — which is public — can make one. So a frame
      // whose body carries no signature is a frame with no author, and until
      // now it was filed under whoever the envelope said, which over the relay
      // is a field the sender chose. Text could be put in somebody else's
      // chat in their name, and so could `conversationClear`, which erases the
      // conversation it lands in.
      //
      // Two exceptions, and only two: image and audio chunks travel unsigned
      // on purpose, because a signature per chunk does not fit in the MTU (see
      // the note where they are sent). What identifies them is the manifest
      // that opens the transfer, which *is* signed, and the AEAD that seals
      // each chunk to a key derived from it.
      //
      // Everything else must be signed, unless it arrived over a Noise link
      // from the very peer the envelope names — which is the direct-neighbour
      // case, authenticated by the handshake, and the one shape older builds
      // still send unsigned control frames in.
      if (verifiedSenderEdPub == null &&
          !unsignedIsAcceptable(
            type: unpacked.type,
            fromTheLinkItself: session?.remotePubkeyHex != null &&
                claimedPub != null &&
                _hexOf(claimedPub) == session!.remotePubkeyHex,
          )) {
        DebugLog.instance.log(
          'CRYPTO',
          'drop unsigned ${unpacked.type.name} from $peerId — '
              'nothing proves who sent it',
        );
        return;
      }

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

      // Old, and not the kind of thing that survives being old.
      if (stale && !survivesReplayWindow(unpacked.type)) return;
      // What the sender's own clock said, falling back to what the relay
      // recorded when they published, and finally to now. All three are the
      // same moment when nothing has gone wrong; they differ exactly when this
      // matters.
      final stamp = _stampFrom(signedAt ?? sentAt);

      switch (unpacked.type) {
        case InnerPayloadType.text:
          final plaintext = utf8.decode(
            unpadTextPayload(unpacked.body),
            allowMalformed: true,
          );
          // A map beacon is transport wearing a text message's clothes: it
          // arrives every 45 seconds while their map is open. Filing it in the
          // conversation would bury the conversation, and — because history is
          // what read receipts are owed on — would have this device acking a
          // beacon every 45 seconds, per friend, forever.
          //
          // Recognised by [SharedLocation.isBeaconText] rather than by the flag
          // alone: the flag is recent, and a friend still on an older build
          // emits the same heartbeat without it. Matching on the shape of the
          // thing — a position that expires within minutes of being sent —
          // catches both, and catches nothing a person chose to send, since the
          // share sheet's shortest window is fifteen minutes.
          final arrivedAt = DateTime.now();
          final beacon = SharedLocation.tryParse(plaintext);
          if (beacon != null &&
              SharedLocation.isBeaconText(plaintext, arrivedAt)) {
            _ref.read(mapPresenceStoreProvider.notifier).record(
                  senderPub != null ? _hexOf(senderPub) : peerId,
                  beacon,
                  sentAt: arrivedAt,
                );
            return;
          }
          DebugLog.instance
              .log('NOISE', 'RX text from $peerId (${plaintext.length} chars)');
          final message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: plaintext,
            sentAt: stamp,
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
            sentAt: stamp,
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
          // The local privacy switch controls what this device sends. If the
          // peer chooses to send a receipt, applying it only updates ticks on
          // our own messages.
          _ingestReceipt(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

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
        case InnerPayloadType.channelModeration:
        case InnerPayloadType.channelHistory:
        // Room business, and this is the one-to-one path: a close arrives in a
        // channel frame or it does not arrive.
        case InnerPayloadType.channelDelete:
          break;

        case InnerPayloadType.forwardPrivacy:
          if (unpacked.body.length != 1 || unpacked.body[0] > 1) {
            DebugLog.instance
                .log('CHAT', 'drop forward-privacy from $peerId: malformed');
            return;
          }
          // Filed under the person, not the road it came in on.
          //
          // `peerId` is the transport — a BLE address, or the literal string
          // `nostr:relay` — and the roster is keyed by pubkey. Written against
          // the transport, the setting landed on a peer nobody has, the real
          // one never changed, and the log said `nostr:relay refuses a link
          // back from a forward`, which is what gave it away. The same
          // confusion the forward attribution itself had.
          if (senderPub == null) {
            DebugLog.instance.log(
              'CHAT',
              'drop forward-privacy from $peerId: no sender to attribute it to',
            );
            return;
          }
          final saysForwardLink = unpacked.body[0] == 0x01;
          final privacyOwner = _hexOf(senderPub);
          await _ref
              .read(knownPeersControllerProvider.notifier)
              .setAllowsForwardLink(privacyOwner, saysForwardLink);
          DebugLog.instance.log(
            'CHAT',
            '${privacyOwner.substring(0, 8)} '
                '${saysForwardLink ? 'allows' : 'refuses'} '
                'a link back from a forward',
          );

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
          // Kept regardless of our own last-seen switch, unlike receipts.
          //
          // That switch is about a *time*: it stops us publishing when we were
          // last in the app, and stops us being told when anybody else was.
          // Dropping the beacon threw away the other thing it carries — who is
          // in the app right now — and left the header claiming nothing at all
          // about somebody who was demonstrably online, which read as broken
          // rather than as private. The time is withheld in the UI instead; see
          // `presenceRecently`.
          _ingestPresence(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
            sentAt: sentAt,
          );

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
            sentAt: stamp,
          );

        case InnerPayloadType.viewOnceConsumed:
          await _ingestViewOnceConsumed(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.albumHint:
          _ingestAlbumHint(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.voiceLevels:
          _ingestVoiceLevels(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.forwardedFrom:
          _ingestForwardedFrom(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.conversationClear:
          await _ingestConversationClear(
            peerId: peerId,
            senderPub: senderPub,
            sentAt: sentAt,
          );

        case InnerPayloadType.copyRestriction:
          await _ingestCopyRestriction(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.conversationWallpaper:
          await _ingestConversationWallpaper(
            peerId: peerId,
            senderPub: senderPub,
            body: unpacked.body,
          );

        case InnerPayloadType.typing:
          // Still gated, and no longer symmetric with presence: hiding your
          // last-seen time now costs you other people's times, not their
          // liveness. Typing is left where it was on purpose — it is the
          // loudest live signal there is, and quietly switching it back on is
          // not something to do to somebody who asked for less of this.
          if (_ref.read(privacySettingsProvider).shareLastSeen) {
            _ingestTyping(
              peerId: peerId,
              senderPub: senderPub,
              body: unpacked.body,
              sentAt: sentAt,
            );
          }

        case InnerPayloadType.channelAvatar:
        case InnerPayloadType.channelDescription:
        case InnerPayloadType.channelAdminOnly:
          // A room's picture, its topic and its posting rule are broadcasts to
          // its members, and only the channel path knows which room a frame
          // belongs to. Arriving on a 1:1 link they name no channel at all, so
          // there is nothing to apply them to.
          break;

        case InnerPayloadType.callSignal:
          // The codec lives in call_signal.dart as of this task; nothing here
          // decodes or dispatches it yet, so a frame is dropped exactly as an
          // unrecognised inner type is dropped today. The state machine that
          // turns this into a ring or a hangup is a later task on this plan.
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
  /// Images and voice notes. Files are still refused: every member relays every
  /// chunk, so a 25 MB attachment is 25 MB across each link in the mesh, and a
  /// manifest claiming a kind this path cannot finish is dropped rather than
  /// half-handled.
  ///
  /// A voice note is a different proposition to a file. It is bounded by how
  /// long anybody is willing to talk, it arrives as AAC at a few kilobytes a
  /// second, and it is the one thing a room was missing that people actually
  /// asked for — so it is carried, on the same manifest-then-chunks path the
  /// photo uses.
  Future<void> _ingestChannelManifest({
    required Channel channel,
    required String authorName,
    required String authorId,
    required Uint8List manifestBytes,
    required DateTime sentAt,
  }) async {
    final MediaManifest manifest;
    try {
      manifest = MediaManifest.decode(manifestBytes);
    } catch (e) {
      DebugLog.instance
          .log('CHAN', 'drop ${channel.name} manifest: malformed ($e)');
      return;
    }
    if (manifest.kind != MediaKind.image &&
        manifest.kind != MediaKind.audio &&
        manifest.kind != MediaKind.avatar) {
      DebugLog.instance.log('CHAN',
          'drop ${channel.name} manifest: ${manifest.kind.name} not carried in channels');
      return;
    }
    _gcMediaBuffers();
    _pendingManifests[_hexOf(manifest.mediaId)] = _ManifestEntry(
      manifest: manifest,
      arrivedAt: DateTime.now(),
      sentAt: sentAt,
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
    required DateTime sentAt,
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
    // The one line that says a transfer started coming in.
    //
    // Every failure on this path was already logged and every success was
    // silent, so a log with no media lines in it read identically whether the
    // sender never sent, the relay never carried it, or it arrived perfectly.
    // Two reports of "circles do not arrive" were unanswerable for exactly
    // that reason. One line per transfer, not per chunk — the buffer is 200
    // lines and a photo batch fills it.
    DebugLog.instance.log(
      'FILE',
      'incoming ${manifest.kind.name} from $peerId — '
          '${manifest.total} chunk(s)${manifest.name == null ? '' : ' '
              '"${manifest.name}"'}',
    );
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
        sentAt: sentAt,
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
      sentAt: sentAt,
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
        // A circle is a file. Dropping a chunk that overtook its manifest
        // leaves the whole transfer waiting forever even though the relay
        // accepted every event.
        case InnerPayloadType.fileChunk:
          await _ingestFileChunk(
            peerId: pc.peerId,
            senderPub: senderPub,
            chunkBytes: unpacked.body,
          );
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
      sentAt: pending.sentAt,
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
    /// When the sender signed the manifest. Null only from a path that has no
    /// manifest of its own to read it from, where the moment of assembly is
    /// the best available answer.
    DateTime? sentAt,
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
          // A room's picture rather than a person's, when the manifest came in
          // on a channel frame. Authorised the way every other room-wide change
          // is: the frame was signed, and only a sender this device already
          // holds as an administrator may set it.
          final room = channel;
          if (room != null) {
            final author = authorId;
            final roster =
                _ref.read(channelRosterControllerProvider.notifier);
            if (author == null || !roster.isAdmin(room.name, author)) {
              DebugLog.instance.log(
                'CHAN',
                'drop ${room.name} picture: sender is not an admin',
              );
              return;
            }
            await _ref
                .read(channelAvatarsControllerProvider.notifier)
                .store(room.name, bytes);
            DebugLog.instance.log(
              'CHAN',
              '${room.name} picture: ${bytes.length}B in place',
            );
            return;
          }
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
          final imageWireId = TransportEnvelope.hashHex(manifest.mediaId);
          message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: manifest.caption ?? manifest.mime,
            sentAt: _stampFrom(sentAt),
            isMine: false,
            kind: MessageKind.image,
            imagePath: path,
            imageMime: manifest.mime,
            // The sender's media id, stable across every path and replay that
            // can deliver this photo — the handle that keeps a re-delivered
            // manifest from adding a second copy to the chat.
            wireId: imageWireId,
            // Kept as well as hashed. A second administrator, or one who
            // restored this room from a backup, can only offer this picture to
            // a newcomer by re-sending it under the id it came in on — see
            // [sendChannelImage].
            mediaId: _hexOf(manifest.mediaId),
            authorName: authorName,
            authorId: authorId,
            viewOnce: manifest.viewOnce,
            // The batch this photo was sent in, when its sender said so. Null
            // when they did not, or when they run a build with nothing to say
            // it with — then grouping falls back to the gap rule in
            // photo_albums.dart, which is where it was before.
            //
            // Taken rather than read: the hint has done its job for this
            // photo, and a re-delivery does not need it again — the bubble it
            // belongs to is already in the chat, already stamped, and dedup
            // stops a second one being made.
            albumId: _pendingAlbums.remove(imageWireId),
          );

        case MediaKind.audio:
          final path = await AudioReassembler.persistToDisk(
            audioId: manifest.mediaId,
            bytes: bytes,
            mime: manifest.mime,
          );
          final audioWireId = TransportEnvelope.hashHex(manifest.mediaId);
          message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: manifest.mime,
            sentAt: _stampFrom(sentAt),
            isMine: false,
            kind: MessageKind.audio,
            audioPath: path,
            audioMime: manifest.mime,
            audioDurationMs: manifest.durationMs,
            wireId: audioWireId,
            // The shape of it, if the levels got here first. Taken rather than
            // read, for the same reason an album id is: this bubble now holds
            // them, and a re-delivery has nothing left to stamp.
            audioLevels: _pendingVoiceLevels.remove(audioWireId),
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

  /// Hold the waiting-for-a-manifest buffers inside a budget that does not
  /// depend on the sender's choices.
  ///
  /// The per-transfer cap counts chunks under one `mediaId`, and the `mediaId`
  /// comes off the wire — a sender that picks a new one every chunk was
  /// bounded by nothing but the manifest TTL, and could hold as much of this
  /// phone's memory as it cared to spend airtime on. Time is not a budget when
  /// the other side controls the rate.
  ///
  /// Oldest transfer first, which is the same rule [_evictOldestManifest] uses
  /// and for the same reason: a manifest travels ahead of its chunks, so the
  /// buffer that has waited longest is the one least likely to still be a real
  /// transfer in progress.
  void _evictPendingFsOverBudget() {
    var bytes = 0;
    for (final list in _pendingFsChunks.values) {
      for (final chunk in list) {
        bytes += chunk.body.length;
      }
    }
    while (_pendingFsChunks.length > _maxPendingFsTransfers ||
        bytes > _maxPendingFsBytes) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final entry in _pendingFsChunks.entries) {
        // An empty list got there by hitting the per-transfer cap and is worth
        // nothing; treat it as the oldest thing there is.
        if (entry.value.isEmpty) {
          oldestKey = entry.key;
          break;
        }
        final at = entry.value.first.arrivedAt;
        if (oldestAt == null || at.isBefore(oldestAt)) {
          oldestAt = at;
          oldestKey = entry.key;
        }
      }
      if (oldestKey == null) break;
      final dropped = _pendingFsChunks.remove(oldestKey);
      if (dropped == null) break;
      for (final chunk in dropped) {
        bytes -= chunk.body.length;
      }
      DebugLog.instance.log(
        'CRYPTO',
        'drop buffered FS chunks for $oldestKey under memory pressure '
            '(${_pendingFsChunks.length} transfers left)',
      );
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

  /// Tell the recipient which photos are one batch, so their copy groups the
  /// way ours does.
  ///
  /// Best-effort on purpose. A hint that does not go out costs the grouping on
  /// their side and nothing else — the photos are unaffected and still arrive
  /// — so nothing in here is allowed to throw into the batch send.
  Future<void> _announceAlbum(List<PendingImageSend> pending) async {
    // One photo is not an album. More than the format holds is not sent at
    // all rather than truncated: a hint naming half a batch would draw a
    // boundary in the wrong place, which is worse than drawing none and
    // letting the gap rule have it.
    if (pending.length < AlbumHint.minPhotos) return;
    if (pending.length > AlbumHint.maxPhotos) {
      DebugLog.instance.log('PHOTO',
          'batch of ${pending.length} exceeds the album hint format — not sent');
      return;
    }
    final first = pending.first;
    try {
      await _sendControlToPeer(
        canonicalId: first.canonicalId,
        peerPub: first.peerPub,
        type: InnerPayloadType.albumHint,
        innerBody:
            AlbumHint(mediaIds: [for (final p in pending) p.imageId]).encode(),
      );
      DebugLog.instance.log(
          'PHOTO', 'album hint: ${pending.length} photos to ${first.canonicalId}');
    } catch (e) {
      DebugLog.instance
          .log('PHOTO', 'album hint did not go out (photos unaffected): $e');
    }
  }

  /// A batch boundary from the other side: stamp the photos of it that have
  /// already landed, and leave the id behind for the ones that have not.
  void _ingestAlbumHint({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final AlbumHint hint;
    try {
      hint = AlbumHint.decode(body);
    } catch (e) {
      DebugLog.instance
          .log('PHOTO', 'drop malformed album hint from $peerId: $e');
      return;
    }
    final wireIds = <String>[
      for (final id in hint.mediaIds) TransportEnvelope.hashHex(id),
    ];
    // Derived from the batch, not minted here. The same hint can arrive twice
    // — a relay re-delivery, a store-and-forward drain — and a fresh id each
    // time would split one batch into two albums, which is the exact failure
    // this whole path exists to remove.
    final albumId = 'w${wireIds.first}';

    for (final wireId in wireIds) {
      _pendingAlbums[wireId] = albumId;
    }
    while (_pendingAlbums.length > _maxPendingAlbums) {
      _pendingAlbums.remove(_pendingAlbums.keys.first);
    }

    // Scoped to this peer's own buckets. A hint only ever names media ids, and
    // ids are the sender's to mint, so applying one chat-wide would let a peer
    // regroup photos somebody else sent. Cosmetic if it happened, and there is
    // no reason to allow it.
    final messages = _ref.read(messagesControllerProvider.notifier);
    final targets = <String>{peerId};
    if (senderPub != null) {
      targets.add(_hexOf(senderPub));
      final sessions = _ref.read(chatSessionManagerProvider);
      for (final entry in sessions.entries) {
        final other = entry.value.remoteStaticPublicKey;
        if (other != null && _pubkeyEquals(other, senderPub)) {
          targets.add(entry.key);
        }
      }
    }
    final wanted = wireIds.toSet();
    var stamped = 0;
    for (final bucket in targets) {
      stamped += messages.applyAlbum(bucket, wanted, albumId);
    }
    DebugLog.instance.log(
        'PHOTO',
        'album hint from $peerId: ${wireIds.length} photos, '
            '$stamped already here');
  }

  /// Send the shape of a voice note that has just gone out.
  ///
  /// Best-effort on purpose, the same way an album hint is: losing this costs
  /// the drawing on their side and nothing else — the audio is a separate
  /// payload and is unaffected — so nothing in here may throw into a send.
  /// Tell the far side who wrote this before it was forwarded.
  ///
  /// Sent after the message and never awaited by it: an attribution that does
  /// not arrive costs a line above a bubble, and a forward that does not
  /// arrive costs the message. The two must not share a fate.
  /// [authorId] is the original author's canonical id, when they permit being
  /// reached through a forward — the caller has already asked. Null keeps the
  /// payload at v1, which every build in the field understands.
  Future<void> announceForwardedFrom({
    required String canonicalId,
    required String wireIdHex,
    required String name,
    String? authorId,
  }) async {
    final peerPub = _resolvePeerPub(canonicalId);
    if (peerPub == null) return;
    try {
      await _sendControlToPeer(
        canonicalId: canonicalId,
        peerPub: peerPub,
        type: InnerPayloadType.forwardedFrom,
        innerBody: ForwardedFrom(
          targetMsgId: _hexDecodeBytes(wireIdHex),
          name: name,
          authorPub: authorId == null ? null : _hexDecodeBytes(authorId),
        ).encode(),
      );
    } catch (e) {
      DebugLog.instance.log(
        'CHAT',
        'forwarded-from did not go out (the message is unaffected): $e',
      );
    }
  }

  /// The attribution from the other side: stamp it on the message if that has
  /// arrived, and hold it if it has not.
  void _ingestForwardedFrom({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final ForwardedFrom hint;
    try {
      hint = ForwardedFrom.decode(body);
    } catch (e) {
      DebugLog.instance
          .log('CHAT', 'drop malformed forwarded-from from $peerId: $e');
      return;
    }
    final wireId = TransportEnvelope.hashHex(hint.targetMsgId);

    // Scoped to this peer's buckets, as the voice levels and the album hint
    // are: nobody gets to write a header onto a message somebody else sent.
    final messages = _ref.read(messagesControllerProvider.notifier);
    final targets = <String>{peerId};
    if (senderPub != null) {
      targets.add(_hexOf(senderPub));
      final sessions = _ref.read(chatSessionManagerProvider);
      for (final entry in sessions.entries) {
        final other = entry.value.remoteStaticPublicKey;
        if (other != null && _pubkeyEquals(other, senderPub)) {
          targets.add(entry.key);
        }
      }
    }
    final authorId = hint.authorPub == null ? null : _hexOf(hint.authorPub!);
    var stamped = false;
    for (final bucket in targets) {
      stamped |= messages.applyForwardedFrom(
        bucket,
        wireId,
        hint.name,
        authorId: authorId,
      );
    }
    if (stamped) return;

    _pendingForwardedFrom[wireId] = _HeldAttribution(hint.name, authorId);
    while (_pendingForwardedFrom.length > _maxPendingVoiceLevels) {
      _pendingForwardedFrom.remove(_pendingForwardedFrom.keys.first);
    }
  }

  Future<void> _announceVoiceLevels({
    required String canonicalId,
    required Uint8List peerPub,
    required Uint8List mediaId,
    required Uint8List bars,
  }) async {
    try {
      await _sendControlToPeer(
        canonicalId: canonicalId,
        peerPub: peerPub,
        type: InnerPayloadType.voiceLevels,
        innerBody:
            VoiceLevels(mediaId: mediaId, levels: bars).encode(),
      );
    } catch (e) {
      DebugLog.instance
          .log('VOICE', 'voice levels did not go out (audio unaffected): $e');
    }
  }

  /// The shape of a voice note from the other side: draw it on the bubble if
  /// the audio is already here, and leave it waiting if it is not.
  void _ingestVoiceLevels({
    required String peerId,
    required Uint8List? senderPub,
    required Uint8List body,
  }) {
    final VoiceLevels levels;
    try {
      levels = VoiceLevels.decode(body);
    } catch (e) {
      DebugLog.instance
          .log('VOICE', 'drop malformed voice levels from $peerId: $e');
      return;
    }
    final wireId = TransportEnvelope.hashHex(levels.mediaId);
    final bars = List<int>.unmodifiable(levels.levels);

    // Scoped to this peer's buckets, exactly as an album hint is: media ids
    // are the sender's to mint, and nobody gets to redraw a voice note
    // somebody else sent.
    final messages = _ref.read(messagesControllerProvider.notifier);
    final targets = <String>{peerId};
    if (senderPub != null) {
      targets.add(_hexOf(senderPub));
      final sessions = _ref.read(chatSessionManagerProvider);
      for (final entry in sessions.entries) {
        final other = entry.value.remoteStaticPublicKey;
        if (other != null && _pubkeyEquals(other, senderPub)) {
          targets.add(entry.key);
        }
      }
    }
    var stamped = false;
    for (final bucket in targets) {
      stamped |= messages.applyVoiceLevels(bucket, wireId, bars);
    }
    if (stamped) return;

    _pendingVoiceLevels[wireId] = bars;
    while (_pendingVoiceLevels.length > _maxPendingVoiceLevels) {
      _pendingVoiceLevels.remove(_pendingVoiceLevels.keys.first);
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
      // The one frame of a transfer that is news. See the parameter.
      wakesPeer: true,
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
    // Hidden from this one contact. Answering nothing is the whole mechanism:
    // their build falls back to the generated gradient, which is what it draws
    // for anybody who has not set a picture, so there is nothing to notice and
    // nothing to explain.
    if (!_ref
        .read(conversationSettingsControllerProvider.notifier)
        .sharesAvatarWith(pubkeyHex)) {
      DebugLog.instance.log(
        'AVATAR',
        'not sending to ${pubkeyHex.substring(0, 8)} — hidden for this contact',
      );
      return;
    }
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
      DebugLog.instance.log(
          'AVATAR', 'not sending to $pubkeyHex: $total chunks is too many');
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
    var expected =
        _ref.read(knownPeersControllerProvider)[pubkeyHex]?.avatarHash;

    // A picture we asked for is a picture we may keep, even if the peer's
    // stored digest has moved on since.
    //
    // Checking only the *current* announcement made this a race the sender
    // could lose by being slow: we ask on an announcement carrying a digest,
    // fourteen chunks take five seconds to arrive, and any announcement in
    // between — one sent before their avatar had loaded from disk, say —
    // clears the field. The bytes then arrive verified, whole, and are thrown
    // away with "nothing announced to match", which is what made avatars look
    // like they load forever: every heartbeat asks again and every answer is
    // discarded.
    //
    // `_avatarRequested` only ever gains entries in [_reconcileAvatar], from
    // the digest of a *verified signed* announcement by that peer. So a hash
    // in it is a commitment they made and signed, which is the property this
    // check exists to enforce — matching it is not a weaker test than matching
    // the stored one, it is the same test against an entry that has not been
    // overwritten yet.
    if (expected == null) {
      final digest = Uint8List.fromList((await Sha256().hash(jpeg)).bytes);
      if (_avatarRequested.contains('$pubkeyHex:${_hexOf(digest)}')) {
        expected = digest;
        DebugLog.instance.log(
          'AVATAR',
          'from $pubkeyHex: announcement cleared mid-transfer, keeping the '
              'picture we asked for',
        );
      }
    }

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
  /// Rate gate for the store-and-forward line — see where it is used.
  DateTime? _lastHoldLogAt;

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
    // Metered for the same reason: forwarding is per-frame and a relay under
    // load emits this faster than anything else in the app.
    _relayMeter.add('ttl=${relayed.ttl} fanout=$fanout', bytes.length);
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

  /// How often the queued-file drain runs when it keeps finding work.
  static const Duration _fileQueueBase = Duration(seconds: 5);

  /// Ceiling on the gap once the queue has been empty for a while.
  static const Duration _fileQueueIdleMax = Duration(minutes: 5);

  /// Current gap, doubling while there is nothing to send.
  ///
  /// This was a flat five seconds, forever: ~17,000 wakeups a day, each one
  /// resolving a provider and filtering the transfer map, on a phone that
  /// spends most of its life asleep in a pocket with an empty queue. The cost
  /// was never the work — there usually is none — it is that a periodic timer
  /// is a wakeup the OS cannot coalesce away, so the processor is denied its
  /// deep idle state all night. That is the background half of the heat.
  ///
  /// So the gap grows while the answer keeps being "nothing", and collapses the
  /// moment that could have changed — see [nudgeFileQueue]. A queued file still
  /// leaves as promptly as before; what got cheap is asking about one that
  /// isn't there.
  Duration _fileQueueGap = _fileQueueBase;

  /// Look at every incoming file that is still arriving, and ask again for any
  /// that has not moved since the last look.
  ///
  /// Progress is the signal rather than a clock on the last chunk, because it
  /// is the thing the transfer centre already keeps and it cannot be fooled by
  /// a chunk that arrives but is refused. Unchanged across a whole
  /// [_stallCheck] with pieces still missing is a transfer that has stopped.
  void _checkStalledMedia() {
    final tasks = _ref.read(fileTransferControllerProvider);
    for (final task in tasks.values) {
      if (task.direction != FileTransferDirection.incoming) continue;
      if (task.status != FileTransferStatus.transferring) continue;
      if (task.totalUnits <= 0) continue;
      final was = _stalledMedia[task.id];
      if (was == null || was.seen != task.completedUnits) {
        // Moving, or newly seen. Either way it is alive; start its count over.
        _stalledMedia[task.id] = (seen: task.completedUnits, asks: 0);
        continue;
      }
      if (task.completedUnits >= task.totalUnits) continue;
      if (was.asks >= _maxStallAsks) continue;
      _stalledMedia[task.id] = (seen: task.completedUnits, asks: was.asks + 1);
      DebugLog.instance.log(
        'FILE',
        'stalled at ${task.completedUnits}/${task.totalUnits} '
            '"${task.fileName}" — asking ${task.chatId} again '
            '(${was.asks + 1} of $_maxStallAsks)',
      );
      unawaited(requestMediaAgain(task.chatId, task.id));
    }
    // Anything that finished or vanished stops being watched.
    _stalledMedia.removeWhere((id, _) {
      final task = tasks[id];
      return task == null ||
          task.status != FileTransferStatus.transferring ||
          task.completedUnits >= task.totalUnits;
    });
  }

  void _startStalledMediaTimer() {
    _stalledMediaTimer?.cancel();
    _stalledMediaTimer = Timer.periodic(_stallCheck, (_) {
      if (_disposed) return;
      _checkStalledMedia();
    });
  }

  void _startFileQueueTimer() {
    _fileQueueTimer?.cancel();
    // One-shot and re-armed, rather than periodic, so the gap can change
    // between runs.
    _fileQueueTimer = Timer(_fileQueueGap, () async {
      await _drainFileQueue();
      if (!_disposed) _startFileQueueTimer();
    });
  }

  /// Put the drain back on its fast cadence and run it now.
  ///
  /// Called whenever something changes that could make a stalled transfer
  /// sendable: a file being queued, a session coming up, the relay connecting.
  /// Without this the back-off would be paid for by the user — a file queued
  /// while backed off would sit for minutes with a live link right there.
  /// Bring the internet transport back up now, rather than on its own backoff.
  ///
  /// Called when the app returns to the foreground. See
  /// [WebSocketNostrRelayClient.wake] for why iOS needs this and Android
  /// mostly does not.
  /// Last time a wake was actually let through, so one cannot be asked for on
  /// every keystroke's worth of failure.
  DateTime? _lastRelayWake;

  /// How close together two wakes may be when something in the app asks for
  /// one. A resume is [force]d past this; a queued message is not.
  static const Duration _relayWakeGap = Duration(seconds: 30);

  /// Ask the relays to come back.
  ///
  /// [force] for the moments that genuinely change the odds — the app
  /// returning to the foreground, an iOS background refresh. Those are rare
  /// and they usually mean the network is different from a moment ago.
  ///
  /// Everything else is rate-limited, and that is the whole point of this
  /// method having a body at all. `wake()` on the client resets the retry
  /// backoff to two seconds and opens immediately, whatever it had grown to —
  /// which is correct for a resume and ruinous on a loop. Sending a message
  /// with no route calls this, so on a phone with no internet every message
  /// pinned the backoff at its floor: a DNS lookup and a socket attempt to
  /// every relay, every two seconds, for as long as the user kept typing. The
  /// backoff grows to two minutes precisely so a dead network is not retried
  /// all day, and that was being undone message by message.
  ///
  /// Reported as the phone getting warm and the app stuttering, and it arrived
  /// in the same build that first called this from the text path.
  void wakeRelays({bool force = false}) {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _lastRelayWake;
    if (!force && last != null && now.difference(last) < _relayWakeGap) return;
    _lastRelayWake = now;
    _relayClient?.wake();
    if (_relayClient?.isConnected == true) {
      nudgeFileQueue();
      unawaited(_flushPendingReadReceipts());
    }
  }

  Future<bool> _ensureRelayAwakeForSend({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final client = _relayClient;
    if (client == null) return false;
    if (client.isConnected) return true;
    client.wake();
    if (client.isConnected) return true;
    try {
      await client.stateChanges
          .firstWhere(
            (_) => client.isConnected || _disposed,
          )
          .timeout(timeout);
    } on TimeoutException {
      // The caller falls back to mesh/store-forward. Keeping this short matters:
      // a send button should feel broken if it blocks behind bad mobile data.
    }
    return !_disposed && client.isConnected;
  }

  void nudgeFileQueue() {
    _fileQueueGap = _fileQueueBase;
    unawaited(_drainFileQueue());
    _startFileQueueTimer();
  }

  Future<void> _drainFileQueue() async {
    if (_drainingFileQueue || _disposed) return;
    _drainingFileQueue = true;
    try {
      await _ref.read(fileTransferControllerProvider.notifier).loaded;
      // The await above is a real gap and this runs from a timer, so the
      // container can be torn down inside it. Reading a disposed one throws
      // into the surrounding zone with nobody listening; nothing below is
      // worth doing for a service that has been disposed anyway.
      if (_disposed) return;
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
      // Anything sendable means the next answer is worth asking for soon;
      // an empty pass is evidence the one after it will be empty too.
      if (queued.isEmpty) {
        final next = _fileQueueGap * 2;
        _fileQueueGap = next >= _fileQueueIdleMax ? _fileQueueIdleMax : next;
      } else {
        _fileQueueGap = _fileQueueBase;
      }
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
  /// whole frames — one event each, no fragmentation — so the size comes from
  /// what one event may weigh instead ([relayMediaChunkData]), which is what
  /// keeps the publish count sane: 140 B chunks would be thousands of publishes
  /// per image.
  ///
  /// The two paths never mix. [_deliverMediaFrame] short-circuits a
  /// relay-chunked transfer straight to the relay, so a 63 KiB chunk is never
  /// handed to the fragmenter as a thousand unpaced BLE notifies.
  int _mediaChunkData(
    BleGattClient? direct, {
    required bool relayOnly,
    required int ceiling,
  }) {
    if (relayOnly) return relayMediaChunkData(ceiling: ceiling);
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

    /// Whether this frame is worth ringing a closed phone for.
    ///
    /// One frame of a transfer is: the manifest. It is the one that says a
    /// picture is coming and who from, and it goes first. The chunks behind it
    /// are the picture itself, and there are five to thirty of them.
    ///
    /// This used to be `true` for every frame that went through here, which is
    /// every chunk. Each one is a separate relay event carrying the wake tag,
    /// so one sticker rang the recipient's phone eight times and three of them
    /// rang it thirty. Reported as "three stickers, thirty-four messages" —
    /// and the count was right, it was counting events.
    bool wakesPeer = false,
  }) async {
    var next = gap;
    for (var attempt = 1; attempt <= _mediaChunkAttempts; attempt++) {
      if (await _deliverMediaFrame(
        frameBytes: frameBytes,
        session: session,
        canonicalId: canonicalId,
        relayOnly: relayOnly,
        wakesPeer: wakesPeer,
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
    bool wakesPeer = false,
  }) async {
    // Everything through here is a chunk or a manifest, which is the whole of
    // what [RelayLane.media] means.
    const lane = RelayLane.media;
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
    return _sendOverNostr(canonicalId, frameBytes,
        wakesPeer: wakesPeer, lane: lane);
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
    for (var i = 0; i < parts.length; i++) {
      await client.writeOutbound(parts[i]);
      if ((i + 1) % _fragmentsBeforeYield == 0) {
        await Future<void>.delayed(_fragmentPacing);
      }
    }
    return true;
  }

  Duration get _fragmentPacing => PlatformInfo.isAndroid
      ? const Duration(milliseconds: 3)
      : const Duration(milliseconds: 1);

  static const int _fragmentsBeforeYield = 8;

  /// Notify one whole frame to every subscribed central via our peripheral,
  /// fragmenting to a conservative MTU (the per-central value isn't reported on
  /// the peripheral side). Returns true only if every fragment was accepted.
  /// The native side queues + drains on backpressure, so a full transmit queue
  /// no longer surfaces here as a failure the way it used to.
  Future<bool> _notifyFrameToPeripheral(Uint8List frameBytes) async {
    final peripheral = _ref.read(blePeripheralProvider);
    final parts = fragmentFrame(frameBytes, conservativeEffectivePayload());
    for (var i = 0; i < parts.length; i++) {
      // Stop at the first refusal rather than pushing the rest of a frame
      // whose middle was turned away. The caller retries whole frames, so the
      // remaining fragments would arrive as the tail of something the far side
      // can never assemble — and they would take the queue slots the retry
      // needs.
      if (!await peripheral.notifyInbound(parts[i])) return false;
      if ((i + 1) % _fragmentsBeforeYield == 0) {
        await Future<void>.delayed(_fragmentPacing);
      }
    }
    return true;
  }

  /// Whether the signed timestamp is older than the replay window.
  ///
  /// Not a verdict on its own any more, and that is the change. It used to be:
  /// past the window, dropped, whatever it was. A phone out of contact for more
  /// than an hour therefore *received* the mail waiting for it on the relay and
  /// then destroyed it — one `drop signed body … stale` line and nothing else,
  /// no gap in the conversation, nothing to notice. Seen in a real log with two
  /// messages in it, 62 and 64 minutes old.
  ///
  /// The sender's own queue could not rescue them either: it holds the built,
  /// already-signed frame, so every retry carries the original timestamp and
  /// every retry after the first hour is refused for certain. Two mechanisms
  /// that both assume an hour is enough, failing together the moment it is not.
  ///
  /// What the window is for is a captured frame re-injected after the dedup
  /// cache forgets it. For anything that lands in the message store that threat
  /// is already answered, permanently and by construction — a replayed message
  /// is recognised by its own id (`skip already-stored message`), and the store
  /// does not expire after an hour. So the window is kept exactly where it is
  /// still the only defence, and lifted where it was never the defence at all.
  /// [_survivesReplayWindow] draws that line.
  bool _pastReplayWindow(int timestampMs, String peerId) {
    final skewMs = DateTime.now().millisecondsSinceEpoch - timestampMs;
    if (skewMs <= _replayMaxAgeMs) return false;
    DebugLog.instance.log(
        'CRYPTO',
        'old signed body from $peerId '
            '(${(skewMs / 1000).round()}s old > replay window)');
    return true;
  }

  /// Whether a payload of this type is safe to accept past the replay window.
  ///
  /// Only what the message store itself dedupes, forever: the text somebody
  /// wrote and the media that travels with it. Everything else keeps the hard
  /// window, because nothing else has a second line of defence — a replayed
  /// receipt, reaction, edit or delete lands on a message that is already
  /// there and changes it, and an edit in particular could put back a version
  /// the sender has since replaced.
  /// Whether a body carrying no signature may be acted on.
  ///
  /// A SealedBox proves nothing about who sealed it: anybody holding the
  /// recipient's public key — which is public — can make one. So an unsigned
  /// body has no author, and the envelope's opinion about who sent it is a
  /// plaintext field the sender wrote. Over the relay that was enough to put
  /// text in somebody else's chat under their name, and enough to send
  /// `conversationClear`, which erases the conversation it lands in.
  ///
  /// Two exceptions, and only two. Image and audio chunks travel unsigned on
  /// purpose — a signature per chunk does not fit in the MTU — and what
  /// identifies them is the manifest that opens the transfer, which is signed,
  /// plus the AEAD that seals each chunk under a key derived from it.
  ///
  /// [fromTheLinkItself] is the other way an unsigned body can be trusted: it
  /// came over a Noise link from the very peer the envelope names, so the
  /// handshake is what vouches for it. That is the direct-neighbour case, and
  /// the shape an older build still sends unsigned control frames in. It is
  /// deliberately not "there is a session" — a relayed frame arrives over a
  /// session too, with somebody else's name on it.
  @visibleForTesting
  static bool unsignedIsAcceptable({
    required InnerPayloadType type,
    required bool fromTheLinkItself,
  }) {
    // Three chunk types, for one reason: a signature per chunk does not fit,
    // and what stands in for it is the signed manifest that opens the transfer.
    //
    // **`fileChunk` was missing, and that is why no file ever arrived over the
    // relay.** A circle travels as a file, so every circle sent over the
    // internet was published in full, carried, received — and then dropped one
    // chunk at a time on the far side. Two logs from 2026-09-09 say it exactly:
    // `[FILE] incoming file from nostr:relay — 74 chunk(s)` at 20:57:45, then
    // `drop unsigned fileChunk … ×43` and `×31`. Forty-three and thirty-one is
    // seventy-four. Not one of them was kept, and the sender had no way to
    // know: nothing acknowledges a transfer end to end.
    //
    // Photos and voice notes were unaffected because they are their own chunk
    // types and both were on the list. That is what made this look like a
    // problem with circles rather than with files.
    //
    // **What holds an unsigned chunk up, and why it is enough.** It is sealed
    // to a key that comes from the manifest — the forward-secret key derived
    // through [MediaFsCipher], or a SealedBox to our own public key — so a
    // chunk that opens at all came from somebody holding it. It is admitted
    // only against a *cached signed* manifest under the same media id, with a
    // matching chunk total; without one it is dropped. And the assembled file
    // is hashed and compared to the SHA-256 the manifest committed to under
    // that signature, so substituted or reordered chunks fail at the end even
    // if they decrypt. The signature is on the transfer, not on each piece of
    // it, which is the same trade image and audio chunks already made.
    if (type == InnerPayloadType.imageChunk ||
        type == InnerPayloadType.audioChunk ||
        type == InnerPayloadType.fileChunk) {
      return true;
    }
    return fromTheLinkItself;
  }

  @visibleForTesting
  static bool survivesReplayWindow(InnerPayloadType type) => switch (type) {
        InnerPayloadType.text ||
        InnerPayloadType.textReply ||
        InnerPayloadType.imageChunk ||
        InnerPayloadType.audioChunk ||
        InnerPayloadType.mediaManifest =>
          true,
        _ => false,
      };

  /// A send time we are willing to write into the transcript.
  ///
  /// Clamped to now, never forward. [_plausibleClock] has already refused
  /// anything wildly ahead, but a few seconds of ordinary clock drift between
  /// two phones would otherwise put a message in the future — where it sorts
  /// above everything, sits under tomorrow's day separator, and stays there.
  DateTime _stampFrom(DateTime? claimed) {
    final now = DateTime.now();
    if (claimed == null || claimed.isAfter(now)) return now;
    return claimed;
  }

  /// Hard drop: a timestamp our clock says has not happened yet.
  ///
  /// Kept absolute, unlike the age above. Nothing legitimate is stamped in the
  /// future, and a frame claiming to be is either a broken clock or somebody
  /// trying to park a message at the top of a conversation forever.
  bool _plausibleClock(int timestampMs, String peerId) {
    final skewMs = DateTime.now().millisecondsSinceEpoch - timestampMs;
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

  /// Resolve a relay sender after its inner signature has already verified.
  ///
  /// The rotating origin id is the normal route back to the canonical X25519
  /// key. Some relay control frames can still be authenticated even when that
  /// origin id no longer maps cleanly (for example after a clock/epoch skew or
  /// a stale roster index), because the full signed body carries the sender's
  /// Ed25519 key. In that case use the verified signer as a fallback so read
  /// receipts, reactions and presence land in the real peer chat instead of
  /// the invisible `nostr:relay` bucket.
  Future<Uint8List?> _canonicalPubForVerifiedSender({
    required Uint8List originPubkeyHash,
    Uint8List? senderEdPub,
  }) async {
    final byOrigin = await _canonicalPubForOrigin(originPubkeyHash);
    if (byOrigin != null) return byOrigin;
    if (senderEdPub == null) return null;

    final peer = _knownPeerBySignKey(senderEdPub);
    if (peer == null) return null;
    try {
      final pub = _hexDecodeBytes(peer.pubkeyHex);
      DebugLog.instance.log(
        'CRYPTO',
        'resolved relay sender ${_short(peer.pubkeyHex)} by verified signer',
      );
      return pub;
    } catch (e) {
      DebugLog.instance.log(
        'CRYPTO',
        'drop relay sender with malformed canonical pubkey: $e',
      );
      return null;
    }
  }

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
  /// Two of these fit inside [PeerPresence.ttl] (150 s), so one dropped beacon
  /// doesn't flicker the dot.
  ///
  /// Raised from 45 s, which was buying a third more of the same work for
  /// nothing. This is the app's most expensive idle loop by a distance: a
  /// beacon is *per peer*, and each one is an Ed25519 signature over the inner
  /// payload, an X25519 seal to that peer, and a secp256k1 Schnorr signature
  /// over the Nostr event — the last of those implemented in Dart in this repo.
  /// Ten contacts is thirty signatures every heartbeat, on a phone that is
  /// sitting still with the app open, which is exactly what "it gets warm doing
  /// nothing" is made of. At 70 s two beacons still fit inside the TTL with
  /// ten seconds to spare, and the dot behaves identically.
  /// **45 s, down from 70 on 2026-09-08.**
  ///
  /// The beacon's period had crept up against its own validity.
  /// [PeerPresence.ttl] is 100 s, so at 70 s a single lost beacon left a
  /// thirty-second hole and the other phone fell back to "last seen recently"
  /// about somebody who was sitting there — reported in exactly those words.
  /// The obvious repair, widening the TTL, is the one that cannot be made:
  /// 150 s was what it used to be, and it was cut to 100 on 2026-09-04 because
  /// a phone that loses its network sends no goodbye and stayed lit for the
  /// whole window. Both complaints are real and they pull opposite ways.
  ///
  /// What resolves them is the gap between the two numbers, and closing it
  /// from this side costs almost nothing — which is a measurement, not a
  /// guess, and the reason the note on [PeerPresence.ttl] refused this. An
  /// "online" beacon is sent only while the app is on screen, so a 99-minute
  /// field log contains **four** rounds, not the eighty-five a 70-second timer
  /// would suggest. Going to 45 s multiplies four by about one and a half, on
  /// the one phone whose screen is already lit.
  ///
  /// Two whole beacons now fit inside the window, so losing one changes
  /// nothing, and a phone that dies without a goodbye still dims inside the
  /// same 100 s it did yesterday.
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
  /// [arriving] marks the one beacon a launch or a return to the app sends, as
  /// against the heartbeat. It takes any road, for the same reason the goodbye
  /// does: it is one frame, once, at the moment the answer changes — and two
  /// phones talking over Bluetooth with no relay had no way to learn it at
  /// all. Reported as somebody opening the app and not appearing on the other
  /// side. The heartbeat stays relay-only; that is the part that would become
  /// chatter.
  Future<void> announcePresence({
    required bool online,
    bool arriving = false,
  }) async {
    if (_disposed) return;
    if (_nostr == null) return;

    // The last-seen switch does not reach this beacon any more.
    //
    // It used to force every beacon to "offline", which is where the status
    // line stopped meaning anything: a phone with the switch off announced
    // itself as not-in-the-app every seventy seconds while its owner was
    // reading a message on it, and the other end dutifully showed "last seen
    // recently" about somebody who was demonstrably there. A log from two
    // phones has nothing in it but `sent offline beacon to 6 peer(s)`, over
    // and over, from an app in active use.
    //
    // What the switch hides is a *time* — see `presenceRecently` and the
    // reading side in peerIsOnline. Whether somebody is in the app right now
    // is not a time and is answered truthfully, which is also the only way the
    // answer can be trusted at all.
    //
    // "Online" therefore means exactly one thing: the app is on screen. A
    // backgrounded process must not claim it, and the goodbye that follows a
    // pause is what corrects the other end.
    if (online && !AppLifecycle.instance.isForeground) return;

    final now = DateTime.now();

    // Second line of defence behind the lifecycle filter in app.dart. One
    // beacon is N peers × M relays of published events, so a caller that fires
    // it in a tight loop is expensive out of proportion to what it conveys —
    // and the relays answer that with a rate limit that lands on real messages
    // too. Re-stating a status we already published this recently buys nothing:
    // the receiver holds it for a TTL that two heartbeats fit inside.
    // The switch is part of what a beacon says, so flipping it has to get
    // through this throttle — otherwise "stop showing my times" waits out the
    // next twenty seconds, or the next heartbeat, before anybody is told.
    final hidden = !_ref.read(privacySettingsProvider).shareLastSeen;
    final since = _lastPresenceAt;
    if (_presenceInFlight ||
        (_lastPresenceOnline == online &&
            _lastPresenceHidden == hidden &&
            since != null &&
            now.difference(since) < _presenceMinInterval)) {
      return;
    }
    // Claimed before the first await, so a concurrent caller sees it.
    _presenceInFlight = true;
    try {
      // Recorded only if it actually went out. Marking the attempt up front —
      // which is what this did — meant a beacon that reached nobody still
      // silenced the next twenty seconds of them, and on a cold start that is
      // every beacon there is: the first one fires while the relay socket is
      // still opening, fails quietly, and the retry two seconds later is
      // discarded as a repeat. Nothing then goes out until the heartbeat
      // seventy seconds on, which is exactly the "you have to leave the app
      // and come back for it to work" this feature kept being accused of.
      if (await _fanOutPresence(
          online: online, now: now, arriving: arriving)) {
        _lastPresenceOnline = online;
        _lastPresenceHidden = hidden;
        _lastPresenceAt = now;
      }
    } finally {
      _presenceInFlight = false;
    }
  }

  /// Say hello to somebody who has just entered the roster.
  ///
  /// The heartbeat only ever tells the people already in it, so a contact
  /// added a moment ago heard nothing until the next tick — reported as a new
  /// friend taking a minute to come online, and it was not the minute, it was
  /// that nobody had said anything to them at all yet.
  ///
  /// Not through [announcePresence]: that throttles a repeat of the same
  /// status within twenty seconds, which is right for re-stating something to
  /// everybody and wrong here. This is not a repeat — it is the first thing
  /// this person has ever been told, and the throttle would swallow it exactly
  /// when contacts are added, which is in bursts.
  void _greetNewPeers(
    Map<String, KnownPeer>? previous,
    Map<String, KnownPeer> next,
  ) {
    if (previous == null || next.length <= previous.length) return;
    if (!AppLifecycle.instance.isForeground) return;
    if (_nostr == null) return;
    final arrived = <KnownPeer>[
      for (final e in next.entries)
        if (!previous.containsKey(e.key) && !e.value.isBlocked) e.value,
    ];
    if (arrived.isEmpty) return;
    unawaited(_greetPeers(arrived));
  }

  Future<void> _greetPeers(List<KnownPeer> peers) async {
    final body = PresenceBeacon(
      online: true,
      hideLastSeen: !_ref.read(privacySettingsProvider).shareLastSeen,
    ).encode();
    var sent = 0;
    for (final peer in peers) {
      if (_disposed) return;
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
          // Whatever road exists, like the arrival beacon it is a special case
          // of: a contact met over Bluetooth may have no relay address at all.
          relayOnly: false,
        );
        if (n > 0) sent++;
      } catch (e) {
        DebugLog.instance.log(
            'PRESENCE', 'hello to ${_short(peer.pubkeyHex)}: $e');
      }
      await Future<void>.delayed(relayFanoutPacing);
    }
    if (sent > 0) {
      DebugLog.instance
          .log('PRESENCE', 'said hello to $sent new contact(s)');
    }
  }

  /// Shortest gap between two beacons saying the same thing. Comfortably below
  /// [presenceHeartbeat] so the heartbeat is never throttled, and far above the
  /// millisecond-scale bursts a lifecycle flap produces.
  static const Duration _presenceMinInterval = Duration(seconds: 20);

  bool? _lastPresenceOnline;
  bool? _lastPresenceHidden;
  DateTime? _lastPresenceAt;
  bool _presenceInFlight = false;

  /// Returns true when at least one peer was actually told.
  Future<bool> _fanOutPresence({
    required bool online,
    required DateTime now,
    bool arriving = false,
  }) async {
    // The goodbye may take any road; "I am here" still takes only the relay.
    //
    // Relay-only is a deliberate decision and stays one for the heartbeat: a
    // second always-on presence channel is the kind of chatter this app has
    // been trimming, and at one beacon per contact every seventy seconds the
    // mesh would carry more presence than conversation.
    //
    // The goodbye is not that. It is one frame, once, at the moment the app
    // goes away — and it is the frame that actually decides whether the other
    // end is telling the truth. Two phones talking over Bluetooth with the
    // relay down sent no goodbye at all, so leaving the app left the other
    // side showing "online" until the beacon aged out two and a half minutes
    // later. That was the report, and it was the transport, not the timing.
    //
    // No new payload type and no new tag: this is the same signed
    // [InnerPayloadType.presence] an older build already reads, and which road
    // it arrived by is not something the receiving side can tell.
    // The hello is the goodbye's twin and had none of its privileges.
    //
    // Everything the paragraph above says about the goodbye is true of the
    // arrival: one frame, once, at the moment the answer changes. Reported as
    // opening the app on one phone and not appearing on the other — and over
    // Bluetooth with no relay reachable there was no road for it at all, so it
    // was not slow, it was absent. The heartbeat is what stays relay-only,
    // because that is the one that repeats.
    final meshHello = online && arriving && _hasAnyLink;
    final meshGoodbye = !online && _hasAnyLink;
    // With no socket up and nothing to hand it to, the fan-out is ten peers of
    // guaranteed failure spaced by [relayFanoutPacing] — a second of wakeful
    // work every 45 s on exactly the phone that has no internet.
    if (_relayClient?.isConnected != true && !meshGoodbye && !meshHello) {
      return false;
    }
    final peers = _ref
        .read(knownPeersControllerProvider)
        .values
        // A Nostr key is what the relay needs; the mesh addresses people by
        // their pubkey and needs no such thing, so the goodbye is not limited
        // to the contacts who happen to have one on file.
        .where((p) =>
            (p.nostrPubkey != null || meshGoodbye || meshHello) &&
            !p.isBlocked &&
            now.difference(p.lastSeen) < _presenceMaxPeerAge)
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    if (peers.isEmpty) return false;

    // The outgoing half of the last-seen switch. Not a lie about being here —
    // a request that the clock beside it is not shown, which is what the
    // setting says and all a mesh can honestly offer: every message already
    // tells the other phone you were alive at that moment.
    final body = PresenceBeacon(
      online: online,
      hideLastSeen: !_ref.read(privacySettingsProvider).shareLastSeen,
    ).encode();
    // The same beacon with the flag set, minted once and only if somebody
    // needs it. A beacon is a signed frame per recipient either way; what is
    // saved here is the encoding, not the sending.
    Uint8List? hiddenBody;
    final settings = _ref.read(conversationSettingsControllerProvider.notifier);
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
      // Hidden from this one contact: the beacon still goes — being reachable
      // is not the secret — but it carries the request that the clock beside
      // the status is not shown, which is exactly what the global switch says
      // to everybody.
      final hiddenHere = !settings.sharesLastSeenWith(peer.pubkeyHex);
      if (hiddenHere && hiddenBody == null) {
        hiddenBody = PresenceBeacon(online: online, hideLastSeen: true).encode();
      }
      try {
        final n = await _sendControlToPeer(
          canonicalId: peer.pubkeyHex,
          peerPub: peerPub,
          type: InnerPayloadType.presence,
          innerBody: hiddenHere ? hiddenBody! : body,
          // See [meshGoodbye] and [meshHello]: the heartbeat keeps to the
          // relay; the goodbye and the arrival take whatever road exists.
          relayOnly: online && !arriving,
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
    return sent > 0;
  }

  /// What a room looks like and how it behaves: its picture, its topic, its
  /// posting rule, its copy rule.
  ///
  /// All four carry the same authorisation, and it is the only one that counts:
  /// the frame's signature says who sent it, and our own roster says whether
  /// they are allowed to change the room.
  ///
  /// Held rather than dropped when the roster cannot answer yet. A roster is
  /// learned from the room over time, so a member who has just joined — or who
  /// has just reinstalled — routinely receives the picture *before* they have
  /// any evidence that the sender is the admin. Dropping it there is
  /// permanent: nobody re-broadcasts a picture, so the room stays a logo
  /// forever, "sometimes" loads depending on which frame arrived first, and
  /// re-entering never fixes it. That was three separate bug reports and one
  /// cause. Once the roster does name that sender an admin, the held frame is
  /// applied — see [_replayHeldChannelState].
  Future<void> _applyOrHoldChannelState({
    required String channelName,
    required InnerPayloadType type,
    required String senderId,
    required Uint8List body,
  }) async {
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    if (!roster.isAdmin(channelName, senderId)) {
      _holdChannelState(channelName, type, senderId, body);
      return;
    }
    await _applyChannelState(channelName, type, body);
  }

  Future<void> _applyChannelState(
    String channelName,
    InnerPayloadType type,
    Uint8List body,
  ) async {
    switch (type) {
      case InnerPayloadType.channelAvatar:
        final avatars = _ref.read(channelAvatarsControllerProvider.notifier);
        await avatars.loaded;
        if (body.isEmpty) {
          await avatars.forget(channelName);
        } else {
          await avatars.store(channelName, AvatarPayload.decode(body).jpeg);
        }

      case InnerPayloadType.channelAdminOnly:
        if (body.isEmpty) return;
        await _ref
            .read(channelControllerProvider.notifier)
            .setAdminOnly(channelName, body[0] == 0x01);

      case InnerPayloadType.copyRestriction:
        // Stored into the "somebody else asked for this" field rather than our
        // own setting, so a member cannot lift a room's restriction for
        // themselves — the 1:1 path draws the same distinction for the same
        // reason.
        if (body.isEmpty) return;
        final settings =
            _ref.read(conversationSettingsControllerProvider.notifier);
        await settings.loaded;
        await settings.setPeerRestrictsCopying(channelName, body[0] == 0x01);

      case InnerPayloadType.channelDescription:
        final descriptions =
            _ref.read(channelDescriptionsControllerProvider.notifier);
        await descriptions.loaded;
        await descriptions.store(
          channelName,
          utf8.decode(body, allowMalformed: true),
        );

      case InnerPayloadType.conversationWallpaper:
        final settings =
            _ref.read(conversationSettingsControllerProvider.notifier);
        await settings.loaded;
        await settings.setWallpaper(
          channelName,
          _wallpaperFromPayload(ConversationWallpaperPayload.decode(body)),
        );

      default:
        break;
    }
  }

  /// Frames whose sender could not be verified yet, by origin hash.
  ///
  /// A message signed compactly needs the sender's verifying key, which only
  /// their announcement carries. When the two race and the message wins, this
  /// is where it waits instead of being thrown away — see the hold in
  /// [_handleTransportFrame].
  ///
  /// Capped per origin and swept by age for the same reason the channel one
  /// is: a stranger whose announcement never arrives must not be able to fill
  /// memory by talking. What is dropped here was unverifiable for a full
  /// minute, which is far longer than the two frames take to cross.
  ///
  /// The sweep runs on the way *in* ([_holdUnverified]) as well as on replay,
  /// because the replay path is reached only by an announcement landing — so
  /// the one peer whose announcement never lands was also the one peer whose
  /// frames were never swept.
  final Map<String, List<_HeldFrame>> _heldUnverified = {};

  /// Whether a frame held at [heldAt] is still worth keeping at [now].
  ///
  /// Static and pure so the rule can be checked without standing a transport
  /// up. Worth pinning because the number that made the bug invisible is a
  /// relationship, not a constant: frames arriving further apart than the TTL
  /// should leave a queue of one, and the shipped log had seventeen.
  @visibleForTesting
  static bool heldFrameIsFresh(DateTime heldAt, DateTime now) =>
      now.difference(heldAt) <= _heldUnverifiedTtl;

  static const int _heldUnverifiedPerOrigin = 20;
  static const Duration _heldUnverifiedTtl = Duration(minutes: 1);

  void _holdUnverified(
    Uint8List originHash,
    String peerId,
    Frame frame,
    DateTime? sentAt,
  ) {
    final key = _hexOf(originHash);
    final held = _heldUnverified.putIfAbsent(key, () => <_HeldFrame>[]);
    final now = DateTime.now();

    // Expire on the way in, because nothing else was ever going to.
    //
    // [_heldUnverifiedTtl] is a minute and the sweep that enforces it lives in
    // [_replayHeldUnverified], which runs only when an announcement arrives.
    // For the one peer this mechanism cannot help — the one whose announcement
    // never comes at all — that is never. A shipped log has the counter
    // climbing 1, 2, 3 … 17 across thirty-five minutes, and not one
    // `replaying` line beside it: every frame in there was minutes past its
    // own deadline, and the only thing bounding the list was the per-origin
    // cap quietly dropping the oldest.
    //
    // Arrival is the right moment for it. It is the only moment the list can
    // grow, it costs a comparison per entry, and it needs no timer to keep
    // alive on a phone that is trying not to wake up.
    final before = held.length;
    held.removeWhere((f) => !heldFrameIsFresh(f.at, now));
    final expired = before - held.length;

    held.add(_HeldFrame(
      peerId: peerId,
      frame: frame,
      sentAt: sentAt,
      at: now,
    ));
    final overCap = held.length > _heldUnverifiedPerOrigin;
    if (overCap) held.removeAt(0);

    // The origin, not the road it came in on.
    //
    // This said `from nostr:relay`, which is a transport and not a person, so
    // a log full of held frames could not say *whose* messages were being
    // lost — and that is the only question worth asking about them. The same
    // confusion cost a build once already, in the forward-privacy handler.
    final who = key.length > 8 ? key.substring(0, 8) : key;
    DebugLog.instance.log(
      'CRYPTO',
      'holding FS body from $who until their announcement '
          '(${held.length} waiting'
          '${expired > 0 ? ', $expired expired' : ''}'
          '${overCap ? ', oldest dropped' : ''})',
    );
  }

  /// Run the held frames again now that somebody's key may have landed.
  ///
  /// Oldest first, so a burst that waited reads in the order it was written.
  /// `replaying: true` because each of these was already counted by the
  /// duplicate check on its first pass; refusing them there is what would make
  /// this whole mechanism a no-op.
  Future<void> _replayHeldUnverified() async {
    if (_heldUnverified.isEmpty) return;
    final now = DateTime.now();
    for (final key in _heldUnverified.keys.toList(growable: false)) {
      final held = _heldUnverified[key];
      if (held == null) continue;
      held.removeWhere((f) => now.difference(f.at) > _heldUnverifiedTtl);
      if (held.isEmpty) {
        _heldUnverified.remove(key);
        continue;
      }
      // Still nobody to check the signature against — leave them waiting.
      if (await _expectedEdPubFor(_hexDecodeBytes(key)) == null) continue;
      _heldUnverified.remove(key);
      DebugLog.instance.log(
        'CRYPTO',
        'replaying ${held.length} held frame(s) from ${key.substring(0, 8)}',
      );
      for (final f in held) {
        try {
          await _handleTransportFrame(
            f.peerId,
            f.frame,
            sentAt: f.sentAt,
            replaying: true,
          );
        } catch (e) {
          DebugLog.instance.log('CRYPTO', 'held frame failed: $e');
        }
      }
    }
  }

  /// Posts waiting on the roster to say their author may speak here.
  ///
  /// Keyed by sender within a room and capped, so a stranger shouting into an
  /// announcement room cannot fill memory: the newest few from any one sender
  /// are kept and the rest let go.
  final Map<String, List<_HeldChannelPost>> _heldChannelPosts = {};

  static const int _heldPostsPerSender = 20;

  void _holdChannelPost({
    required String channelName,
    required String senderId,
    required Future<void> Function() deliver,
  }) {
    final key = '$channelName|$senderId';
    final held = _heldChannelPosts.putIfAbsent(key, () => <_HeldChannelPost>[]);
    held.add(_HeldChannelPost(deliver: deliver, at: DateTime.now()));
    if (held.length > _heldPostsPerSender) held.removeAt(0);
  }

  /// Deliver what the roster has since authorised, oldest first so a room
  /// reads in the order it was spoken in.
  Future<void> _replayHeldChannelPosts() async {
    if (_heldChannelPosts.isEmpty) return;
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final now = DateTime.now();
    for (final key in _heldChannelPosts.keys.toList(growable: false)) {
      final separator = key.lastIndexOf('|');
      final channelName = key.substring(0, separator);
      final senderId = key.substring(separator + 1);
      final held = _heldChannelPosts[key];
      if (held == null) continue;
      held.removeWhere(
          (post) => now.difference(post.at) > _heldChannelStateTtl);
      if (held.isEmpty || !roster.isAdmin(channelName, senderId)) {
        if (held.isEmpty) _heldChannelPosts.remove(key);
        continue;
      }
      _heldChannelPosts.remove(key);
      DebugLog.instance.log(
          'CHAN', 'delivering ${held.length} held post(s) in $channelName');
      for (final post in held) {
        try {
          await post.deliver();
        } catch (e) {
          DebugLog.instance.log('CHAN', 'held post failed in $channelName: $e');
        }
      }
    }
  }

  /// Frames waiting on the roster to say who is allowed to have sent them.
  ///
  /// One per room and kind, newest wins: a picture set twice while we still
  /// know nothing is one picture, the later one. Memory only — a restart
  /// re-reads nothing and simply waits for the next broadcast, which is where
  /// this started.
  final Map<String, _HeldChannelState> _heldChannelState = {};

  /// How long a frame from an unproven sender is worth keeping. Long enough to
  /// cover a roster arriving over a slow mesh; short enough that a member who
  /// never was an admin cannot leave something parked in memory for a week.
  static const Duration _heldChannelStateTtl = Duration(hours: 6);

  static const int _heldChannelStateCap = 24;

  void _holdChannelState(
    String channelName,
    InnerPayloadType type,
    String senderId,
    Uint8List body,
  ) {
    DebugLog.instance.log('CHAN',
        'hold ${channelName} ${type.name} from $senderId: not a known admin yet');
    if (_heldChannelState.length >= _heldChannelStateCap) {
      // Oldest out. This only fills up under a stream of unauthorised frames,
      // which is somebody trying it on rather than a room being used.
      final oldest = _heldChannelState.entries
          .reduce((a, b) => a.value.at.isBefore(b.value.at) ? a : b);
      _heldChannelState.remove(oldest.key);
    }
    _heldChannelState['$channelName|${type.name}'] = _HeldChannelState(
      senderId: senderId,
      body: body,
      at: DateTime.now(),
    );
  }

  /// Apply anything the roster has since authorised, and forget what has gone
  /// stale. Runs on every roster change.
  Future<void> _replayHeldChannelState() async {
    if (_heldChannelState.isEmpty) return;
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    final now = DateTime.now();
    for (final key in _heldChannelState.keys.toList(growable: false)) {
      final held = _heldChannelState[key];
      if (held == null) continue;
      if (now.difference(held.at) > _heldChannelStateTtl) {
        _heldChannelState.remove(key);
        continue;
      }
      final separator = key.lastIndexOf('|');
      final channelName = key.substring(0, separator);
      final typeName = key.substring(separator + 1);
      if (!roster.isAdmin(channelName, held.senderId)) continue;
      final type =
          InnerPayloadType.values.where((t) => t.name == typeName).firstOrNull;
      _heldChannelState.remove(key);
      if (type == null) continue;
      DebugLog.instance.log(
          'CHAN', 'applying held $channelName $typeName — admin confirmed');
      try {
        await _applyChannelState(channelName, type, held.body);
      } catch (e) {
        DebugLog.instance.log('CHAN', 'held $channelName $typeName failed: $e');
      }
    }
  }

  /// Somebody new in a room we run: tell them what it looks like.
  ///
  /// A picture is broadcast once, at the moment it is set, and nothing repeats
  /// it — so everybody who joined afterwards saw a room with no picture and no
  /// topic, permanently, and the only cure was the admin setting it again. The
  /// receiving end of that same gap is [_holdChannelState]; this is the half
  /// that was never sent at all.
  ///
  /// Only what we are entitled to send: [sendChannelAvatar] and
  /// [sendChannelDescription] both refuse unless this phone is the room's
  /// admin, which is exactly the right answer for a member who happens to
  /// notice somebody joining.
  void _noteNewRoomMembers(
    Map<String, Map<String, ChannelMember>>? previous,
    Map<String, Map<String, ChannelMember>> next,
  ) {
    if (previous == null) return;
    for (final entry in next.entries) {
      final before = previous[entry.key];
      // A room appearing for the first time is us joining it, not somebody
      // joining us — there is nobody to catch up and the picture is on its way
      // to us, not from us.
      if (before == null) continue;
      final arrived = entry.value.keys.where((id) => !before.containsKey(id));
      if (arrived.isEmpty) continue;
      _roomsToIntroduce.add(entry.key);
    }
    if (_roomsToIntroduce.isEmpty) return;
    // Debounced: a roster catches up in bursts — a dozen members can land in a
    // second after a reconnect — and each broadcast reaches the whole room.
    _introduceRoomsTimer?.cancel();
    _introduceRoomsTimer = Timer(const Duration(seconds: 5), () {
      _introduceRoomsTimer = null;
      unawaited(_introduceRooms());
    });
  }

  /// Rooms where we have already answered somebody else's claim on the seat,
  /// keyed by room and claimant. One answer each, or two phones re-announcing
  /// at each other fills the air with nothing.
  final Set<String> _seatDefended = {};

  final Set<String> _roomsToIntroduce = {};
  Timer? _introduceRoomsTimer;

  Future<void> _introduceRooms() async {
    final rooms = _roomsToIntroduce.toList(growable: false);
    _roomsToIntroduce.clear();
    for (final room in rooms) {
      final picture =
          _ref.read(channelAvatarsControllerProvider.notifier).forChannel(room);
      final description =
          _ref.read(channelDescriptionsControllerProvider)[room];
      final channel = _ref.read(channelControllerProvider.notifier).byName(room);
      final offersHistory = channel?.shareHistory ?? false;
      if (picture == null &&
          (description == null || description.isEmpty) &&
          !offersHistory) {
        continue;
      }
      try {
        if (picture != null) await sendChannelAvatar(room, picture);
        if (description != null && description.isNotEmpty) {
          await sendChannelDescription(room, description);
        }
        // And the backlog, when the room is set to hand it over on its own.
        //
        // This is the whole of the switch: somebody new turns up in the
        // roster, and what they missed goes out behind the picture and the
        // topic that already do. Harmless for everybody else — the posts carry
        // the ids they originally travelled under, so a member who was here
        // receives them and stores nothing.
        //
        // [sendChannelHistory] throws for a room this phone may not speak for,
        // which is the ordinary case and is already caught below.
        if (channel?.shareHistory ?? false) {
          await sendChannelHistory(room);
        }
        DebugLog.instance.log('CHAN', 're-shared $room state with new members');
      } catch (e) {
        // Not our room to describe — the usual case, and not worth a word
        // beyond the log.
        DebugLog.instance.log('CHAN', 'no re-share for $room: $e');
      }
    }
  }

  /// A room's backlog, offered by an administrator.
  ///
  /// Idempotent by construction: every post carries the wireId the original
  /// travelled under, and [MessagesController.append] already refuses a
  /// wireId it holds. So this lands only where a post is missing — everybody
  /// who was in the room when it was said stores nothing, and the person who
  /// just joined gets what they missed.
  ///
  /// Refused outside an announcement channel. A channel frame is signed by
  /// whoever sent it, so a backlog carries the sender's signature over
  /// somebody else's words; in a room where only administrators post those are
  /// the administrator's own words and the signature says what it should, and
  /// anywhere else it would be a licence to put sentences in other people's
  /// mouths.
  Future<void> _ingestChannelHistory({
    required Channel channel,
    required String senderId,
    required Uint8List body,
  }) async {
    final roster = _ref.read(channelRosterControllerProvider.notifier);
    if (!channel.adminOnly || !roster.isAdmin(channel.name, senderId)) {
      DebugLog.instance.log(
        'CHAN',
        'drop ${channel.name} history: not an admin-only room, or not an admin',
      );
      return;
    }
    final ChannelHistory history;
    try {
      history = ChannelHistory.decode(body);
    } catch (e) {
      DebugLog.instance.log('CHAN', 'drop ${channel.name} history: $e');
      return;
    }
    final messages = _ref.read(messagesControllerProvider.notifier);
    // The roster is where a fingerprint becomes a name; it recorded this
    // sender a few lines before we got here.
    final name = _ref
            .read(channelRosterControllerProvider)[channel.name]?[senderId]
            ?.name ??
        channel.name;
    var added = 0;
    for (final post in history.posts) {
      final wireId = TransportEnvelope.hashHex(post.wireId);
      final landed = messages.append(
        channel.name,
        Message(
          id: 'h$wireId',
          chatId: channel.name,
          text: post.text,
          sentAt: post.sentAt,
          isMine: false,
          status: MessageStatus.delivered,
          authorId: senderId,
          authorName: name,
          wireId: wireId,
        ),
      );
      if (landed) added++;
    }
    DebugLog.instance.log(
      'CHAN',
      '${channel.name} history: $added of ${history.posts.length} were new',
    );
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
    DateTime? sentAt,
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
    // Dated by the sender, and never later than now.
    //
    // The beacon itself carries no clock, so this is the event's `created_at`
    // — which is a claim the sender makes, hence the clamp: without it a peer
    // could stay permanently "in the app" by dating every beacon a year ahead.
    // Clamping only ever makes a beacon look older, which is the safe
    // direction for a freshness test.
    //
    // Getting this wrong is the bug being fixed. A relay keeps events for
    // whoever subscribes next, so the last "I am here" a phone managed before
    // it died was handed to us on our next launch and stamped with *our*
    // clock. The owner had switched the phone off inside the app, and the
    // header said they were online — for a fresh 150 seconds every time the
    // relay reconnected.
    final now = DateTime.now();
    final stamp =
        (sentAt == null || sentAt.isAfter(now)) ? now : sentAt;
    // Past believing before it is even recorded. A backlog beacon says what
    // somebody was doing at a moment that has gone; it is history, and the
    // only thing left to do with it is the last-seen mark below.
    final fresh = now.difference(stamp) < PeerPresence.ttl;
    if (fresh) {
      _ref.read(presenceControllerProvider.notifier).record(
            canonical,
            online: beacon.online,
            hidesLastSeen: beacon.hideLastSeen,
            at: stamp,
          );
    }
    // Both kinds of beacon are evidence of life *now* — a goodbye most of all,
    // since it is the last thing they did before closing the app. Refreshing
    // only on "hello" left the header showing the moment they *arrived*
    // ("offline · 00:57" an hour into a conversation), when what the reader
    // wants is when they left.
    //
    // Safe because [peerIsOnline] gives a fresh beacon precedence over
    // lastSeen: a peer who just said goodbye still reads as offline, now with
    // a timestamp that means "just now" instead of one that means nothing.
    //
    // At the beacon's own moment, not at ours, for the same reason: a beacon
    // that waited on a relay is evidence of life *then*. [markPresent] never
    // moves the mark backwards, so a stale one cannot undo a fresher answer.
    _ref
        .read(knownPeersControllerProvider.notifier)
        .markPresent(canonical, at: stamp);
    DebugLog.instance.log(
      'PRESENCE',
      '${canonical.substring(0, 8)} is '
          '${beacon.online ? 'online' : 'offline'}'
          '${fresh ? '' : ' (stale by ${now.difference(stamp).inMinutes} min)'}',
    );
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

  /// Offer one member of a room our contact card, so they can write to us
  /// outside it.
  ///
  /// The only direction a room allows. A channel frame carries its author's
  /// signing *fingerprint* and never their public key, so a member cannot be
  /// added from what the room shows — which is what makes "invite them" mean
  /// "hand them mine". The card is the whole signed announcement, prekey
  /// included, because a stranger has nothing of ours on file and a bare
  /// pubkey would name somebody they still could not encrypt to.
  ///
  /// Posted into the room rather than sent privately, for the same reason:
  /// there is no private route to somebody we have never met. Everyone in the
  /// room can see it — as they can see everything else posted there — and the
  /// `to` field is what lets one member's app say the invitation is theirs
  /// while everybody else's stays quiet about it.
  Future<void> sendChannelContactInvite(
    String channelName,
    String memberId,
  ) async {
    final identity = await _ref.read(identityProvider.future);
    final invite = SharedContact(
      pubkeyHex: _hexOf(Uint8List.fromList(identity.publicKey)),
      displayName: _ref.read(nicknameControllerProvider),
      invitedMemberId: memberId,
      card: await myContactCard(),
    );
    await sendChannelText(channelName, invite.encode());
    DebugLog.instance.log('CHAN', 'offered contact card to $memberId');
  }

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
    // Adding somebody from their card lifts a previous removal, and forgetting
    // that made them unaddable.
    //
    // The tombstone stops an announcement, a beacon or a handshake from
    // *creating* a roster entry — that is its whole job, and it is why a
    // removed contact no longer walks back in off the radio. `_ingestAnnouncement`
    // shares these two lines and must keep being blocked. A card is the other
    // thing entirely: the owner of the phone deliberately saying "this person".
    //
    // Without this the upsert below returned at that guard, so scanning the
    // code did nothing at all — no contact, and no avatar either, because there
    // was no entry to hang one on. Reported as both.
    //
    // It only bites somebody with no roster entry left, which means people
    // removed by builds up to 944: those deleted the entry as well. A removal
    // made now keeps it and blocks nothing.
    await _ref
        .read(removedContactsControllerProvider.notifier)
        .restore(pubkeyHex);
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
    // Somebody who writes is NOT a contact again, and used to be.
    //
    // The old reasoning was that mail is never worth losing to a preference,
    // and it was sound while removing a contact deleted the conversation with
    // them: a message from a removed person had nowhere to land, so the
    // removal had to be undone first. That is no longer true. Removing a
    // contact keeps the roster entry and the whole conversation now — see
    // `removeFromContacts` — so their message arrives, is stored, and shows in
    // the chat list exactly as it always did. Nothing is lost by leaving them
    // off the Contacts screen.
    //
    // What was lost was the decision. Somebody tidied their list, the other
    // person wrote a week later, and the row came back with no explanation —
    // which is the same complaint that started this, seen from the other end.
    //
    // The way back is a button on their profile, which is where somebody who
    // wants them back is already looking.
    // Canonical key (lives forever, used by chats list). A false return means
    // this exact wireId is already in the chat — a relay backlog replay or a
    // second delivery path — so there is nothing to fan out and nothing to
    // notify about either.
    // An attribution that beat its own message here. Taken rather than read:
    // this bubble now holds it, and a re-delivery has nothing left to stamp.
    final held = message.wireId == null
        ? null
        : _pendingForwardedFrom.remove(message.wireId);
    if (held != null) {
      message = message.copyWith(
        forwardedFrom: held.name,
        forwardedFromId: held.authorId,
      );
    }
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

    // Stored under the pubkey and nowhere else.
    //
    // This used to fan the message out to every open session keyed by BLE
    // address as well, so a chat opened from Nearby — which navigates by
    // address — would see it. The guard was sound at the moment of writing:
    // only sessions whose remote static key matched the sender got a copy.
    //
    // What it could not guard is *later*. Android rotates its BLE address,
    // and the same log that shows this fan-out shows one peer arriving under
    // three different addresses in as many minutes. The bucket keyed by the
    // old address keeps the old name and is still on disk when that address
    // belongs to somebody else — which is how a message from one phone landed
    // in another phone's conversation, and it is precisely the mistake the
    // wire notes warn about: a peer id is never a stable key.
    //
    // Nothing is lost by stopping. The chat screen already prefers the
    // canonical bucket and only falls back to the transport id while no
    // session has resolved a pubkey yet — and a message that decrypted has a
    // session by definition, so by the time one exists the screen is reading
    // the pubkey.
    DebugLog.instance.log('NOISE', 'appended to canonical=$pubkeyHex');

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
    // And a muted room. A channel has no [KnownPeer] to hang a mute on — the
    // line above can only ever answer for a person — so rooms keep theirs with
    // the conversation. See [ConversationSettings.muted].
    if (_ref
        .read(conversationSettingsControllerProvider.notifier)
        .isMuted(canonicalId)) {
      return;
    }
    // The English constant this was is the one word on the banner that is not
    // the sender's own name, so it was also the only word the app got to
    // choose — and it chose English, on a phone whose every other line was
    // Ukrainian. The preview below has been localised since it was written;
    // the title beside it was not.
    final name = (known?.displayName.isNotEmpty ?? false)
        ? known!.displayName
        : _localizations.notificationUnknownSender;
    // The same line the chat list shows, in the language the app is set to: a
    // notification used to announce '📷 Photo' for a sticker and, in English,
    // to somebody using the app in Ukrainian.
    final preview = messagePreview(message, _localizations);
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
    // …and the rooms. A channel frame is addressed to nobody, so it is not in
    // the store above — without this, everything posted while this neighbour
    // was out of range is lost to them, which is what "channels do not work
    // over Bluetooth" actually is.
    unawaited(_replayChannelFramesTo(session));
    // A link coming up is the event the queued-file drain has been backing off
    // waiting for. Without this the back-off would be charged to the user: a
    // file queued for someone who just walked into range would sit for minutes
    // with a live link right there.
    nudgeFileQueue();
    // A copy restriction set while they were away never reached them, and
    // there is no acknowledgement that would have told us. A session coming up
    // is the cheapest moment to say it — one frame, only when the answer is
    // "off" (the default needs no announcing), and only once per run however
    // many times the link drops and comes back.
    unawaited(announceCopyRestriction(pubkeyHex));
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

  /// Mesh forwarding, one line per second per outcome rather than per frame.
  final _relayMeter = TrafficMeter('MESH', 'relayed');

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

  /// True when we are already talking to this identity, on any address and in
  /// either direction.
  ///
  /// [hasLinkOrPendingTo] answers about one BLE address, and an address is not
  /// a person: a peer rotates through several, and a peer that dialled *us*
  /// has no entry there at all. A phone in a busy room was therefore seen as
  /// unconnected on every address it had ever advertised, and dialled on each
  /// of them — in one log, the same contact was chased at a dead address for
  /// twenty seconds, in a storm of GATT 133s, while their messages were
  /// arriving over the link they had opened themselves.
  bool hasSessionWithPubkey(String pubkeyHex) {
    for (final session in _ref.read(chatSessionManagerProvider).values) {
      if (session.remotePubkeyHex != pubkeyHex) continue;
      switch (session.status) {
        case ChatSessionStatus.established:
        case ChatSessionStatus.handshakingInitiator:
        case ChatSessionStatus.handshakingResponder:
          return true;
        default:
          continue;
      }
    }
    return false;
  }

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
    _stalledMediaTimer?.cancel();
    _stalledMediaTimer = null;
    _stalledMedia.clear();
    _introduceRoomsTimer?.cancel();
    _introduceRoomsTimer = null;
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
    required this.frameBytes,
  });
  final String canonicalId;
  final String chatId;
  final String messageId;

  /// The frame exactly as it would have gone out, kept so a relay coming up
  /// can carry it without the message being composed again.
  ///
  /// The same bytes the store-and-forward buffer holds — already sealed and
  /// signed, so keeping a second reference costs a pointer, not a copy, and
  /// the relay learns nothing from it that Bluetooth would not have shown.
  final Uint8List frameBytes;
}

/// One signed media manifest awaiting its chunks. Holds enough context
/// to attribute the resulting Message to the right peer once the bytes
/// have caught up.
class _ManifestEntry {
  _ManifestEntry({
    required this.manifest,
    required this.arrivedAt,
    required this.sentAt,
    required this.peerId,
    required this.senderPub,
    this.channel,
    this.authorName,
    this.authorId,
  });
  final MediaManifest manifest;
  final DateTime arrivedAt;

  /// When the sender says they sent it — their signed timestamp, not the
  /// moment the last chunk landed. A photo over Bluetooth finishes arriving
  /// minutes after it was sent, and the transcript used to show the second
  /// number; the album grouping read it too, which is why two photos sent
  /// together over a slow link drew as two bubbles.
  final DateTime sentAt;

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

/// A room's picture, topic or rule, waiting on the roster to confirm that the
/// person who sent it was allowed to. See [MessagingService._holdChannelState].
class _HeldChannelState {
  _HeldChannelState({
    required this.senderId,
    required this.body,
    required this.at,
  });

  final String senderId;
  final Uint8List body;
  final DateTime at;
}

/// A channel post whose author is not yet known to be allowed to speak in an
/// announcement room. See [MessagingService._holdChannelPost].
class _HeldFrame {
  const _HeldFrame({
    required this.peerId,
    required this.frame,
    required this.sentAt,
    required this.at,
  });

  final String peerId;
  final Frame frame;
  final DateTime? sentAt;

  /// When it was held, so it can be given up on rather than kept forever.
  final DateTime at;
}

class _HeldChannelPost {
  _HeldChannelPost({required this.deliver, required this.at});

  final Future<void> Function() deliver;
  final DateTime at;
}

/// A room frame kept briefly so a neighbour arriving late can be caught up.
/// See [MessagingService._rememberChannelFrame].
class _RecentChannelFrame {
  _RecentChannelFrame({required this.bytes, required this.at});

  final Uint8List bytes;
  final DateTime at;
}

/// An attribution that arrived before the message it belongs to.
///
/// Held by wireId until the bubble turns up — the two travel as separate
/// payloads on purpose, so either order is ordinary.
class _HeldAttribution {
  const _HeldAttribution(this.name, this.authorId);

  final String name;
  final String? authorId;
}
