import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'package:cryptography/cryptography.dart';

import '../../features/channels/data/channel_controller.dart';
import '../../features/channels/models/channel.dart';
import '../../features/chat/data/messages_controller.dart';
import '../../features/chat/models/message.dart';
import '../../features/peers/data/known_peers_controller.dart';
import '../../features/peers/data/peripheral_controller.dart';
import '../../features/peers/models/known_peer.dart';
import '../ble/ble_peripheral.dart';
import '../crypto/channel_crypto.dart';
import '../crypto/fs_message.dart';
import '../crypto/identity_service.dart';
import '../crypto/prekey_service.dart';
import '../crypto/sealed_box.dart';
import '../crypto/signed_payload.dart';
import '../crypto/x3dh.dart';
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
import 'dedup_cache.dart';
import 'store_forward_cache.dart';
import 'envelope.dart';
import 'frame.dart';
import 'image_reassembly.dart';
import 'inner_payload.dart';
import '../crypto/media_fs_cipher.dart';

/// Wall-clock deadline for the full Noise XX exchange — initiator + responder
/// together. If a session is still handshaking after this, we tear it down and
/// surface a failed state to the UI so the user can retry instead of staring
/// at a "secure channel forming" spinner indefinitely.
const _handshakeTimeout = Duration(seconds: 15);

/// How often we re-broadcast our (pubkey, nickname) announcement on every
/// active link. Matches the cadence of bitchat-style mesh announcements —
/// slow enough to keep BLE airtime cheap, fast enough that a fresh peer
/// joining mid-conversation learns the roster within a minute.
const _announcementInterval = Duration(seconds: 60);

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
    unawaited(_loadRelayBuffer());
    unawaited(_ref.read(prekeyServiceProvider).ensureInitialized());
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

  /// Conservative single-frame ceiling. A forward-secret text frame whose
  /// total wire size would exceed this falls back to SealedBox so we never
  /// produce a frame the BLE MTU (247) can't carry in one write.
  static const int _maxFsWireBytes = 240;

  final Ref _ref;
  final _clients = <String, BleGattClient>{}; // central-side clients
  final _handshakeTimers = <String, Timer>{}; // peerId -> watchdog timer
  StreamSubscription<PeripheralEvent>? _peripheralEventsSub;
  Timer? _announcementTimer;

  /// Cached pubkey hash of the local identity, computed lazily on first use.
  /// Used as the `originPubkeyHash` on every outbound transport envelope.
  Uint8List? _myHashCache;

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

  Future<Uint8List> _myPubkeyHash() async {
    if (_myHashCache != null) return _myHashCache!;
    final id = await _ref.read(identityProvider.future);
    final digest = await Blake2s().hash(id.publicKey);
    _myHashCache = TransportEnvelope.shortHashFromHashBytes(
        Uint8List.fromList(digest.bytes));
    return _myHashCache!;
  }

  Future<Uint8List> _peerPubkeyHash(Uint8List peerPubkey) async {
    final digest = await Blake2s().hash(peerPubkey);
    return TransportEnvelope.shortHashFromHashBytes(
        Uint8List.fromList(digest.bytes));
  }

  /// Prepend the 1-byte cipher tag to an encrypted body.
  static Uint8List _tagBody(int cipher, Uint8List body) {
    final out = Uint8List(1 + body.length);
    out[0] = cipher;
    out.setRange(1, out.length, body);
    return out;
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
      DebugLog.instance.log('CRYPTO',
          'media FS setup failed ($e) — SealedBox fallback');
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
    final session = await manager.startInitiator(peerId, peerLabel: displayName);

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
    // need ≥ ~100B effective payload. With Android default MTU of 23 that
    // gives only 20B of usable notify space, which silently truncates HS2
    // and the handshake stalls forever.
    if (client.negotiatedMtu < 100) {
      DebugLog.instance.log('NOISE', 'WARNING: MTU=${client.negotiatedMtu} '
          'is too small for handshake frames — handshake may stall');
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
      DebugLog.instance.log('NOISE',
          'handshake TIMEOUT for $peerId (status=${session.status})');
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
  Future<Message> sendText(String chatId, String text) async {
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
          DebugLog.instance.log('MESH',
              'sendText: malformed pubkey hex for $chatId: $e');
        }
      }
    }

    if (peerPub == null || canonicalId == null) {
      throw StateError('cannot send: no recipient pubkey for $chatId');
    }

    // Mint the transport msgId up front so the local Message can record it as
    // its wireId — the stable handle a read receipt / reaction from the peer
    // will reference back.
    final msgId = TransportEnvelope.newMsgId();
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
          final innerFs = packInnerPayload(
            InnerPayloadType.text,
            padTextPayload(utf8Text, bucket: 0),
          );
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
            senderEphemeralPub:
                Uint8List.fromList((ephemeral.publicKey).bytes),
          );
          final tagged = _tagBody(_cipherX3dh, fsBody);
          // wire = frame(1) + envelope header + tagged body
          final wireLen = 1 + TransportEnvelope.headerLen + tagged.length;
          if (wireLen <= _maxFsWireBytes) {
            body = tagged;
            messages.markForwardSecret(canonicalId, msg.id);
            if (chatId != canonicalId) {
              messages.markForwardSecret(chatId, msg.id);
            }
            DebugLog.instance.log('CRYPTO',
                'sendText: forward-secret (X3DH) to $canonicalId '
                '(${wireLen}B wire)');
          } else {
            DebugLog.instance.log('CRYPTO',
                'sendText: FS frame ${wireLen}B > $_maxFsWireBytes — '
                'falling back to SealedBox');
          }
        } catch (e) {
          DebugLog.instance.log('CRYPTO',
              'sendText: FS path failed ($e) — falling back to SealedBox');
          body = null;
        }
      }

      if (body == null) {
        // SealedBox path (no FS). Full signature (0xA1) + length padding.
        final inner = packInnerPayload(
          InnerPayloadType.text,
          padTextPayload(utf8Text),
        );
        final signed = await SignedPayload.wrap(
          inner: inner,
          context: ctx,
          signKeyPair: identity.asSignKeyPair(),
          senderEdPub: identity.signPublicKey,
        );
        body = _tagBody(_cipherSealedBox, await SealedBox.seal(signed, peerPub));
      }

      final envelope = TransportEnvelope(
        originPubkeyHash: myHash,
        destPubkeyHash: peerHash,
        msgId: msgId,
        ttl: TransportEnvelope.defaultTtl,
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
      // Every delivery attempt is wrapped so a transient BLE failure (stale
      // link, peer's Bluetooth turned off, write rejected) leaves
      // deliveredVia == 0 and routes the message into the pending outbox —
      // it must NOT throw to the outer catch and mark the message failed.
      if (transportId != null) {
        final client = _clients[transportId];
        if (client != null && client.isConnected) {
          try {
            await client.writeOutbound(wireBytes);
            deliveredVia = 1;
          } catch (e) {
            DebugLog.instance.log('MESH', 'direct write failed ($e) — will queue');
          }
        }
        if (deliveredVia == 0) {
          try {
            final ok = await _ref
                .read(blePeripheralProvider)
                .notifyInbound(wireBytes);
            if (ok) deliveredVia = 1;
          } catch (_) {}
        }
        if (deliveredVia == 0) {
          deliveredVia = await _fanoutAllLinks(wireBytes, excludePeerId: null);
        }
      } else {
        deliveredVia = await _fanoutAllLinks(wireBytes, excludePeerId: null);
      }

      if (deliveredVia > 0) {
        messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
        if (chatId != canonicalId) {
          messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
        }
      } else {
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
        DebugLog.instance.log('MESH',
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
  Future<Message> sendImage(
    String chatId, {
    required Uint8List bytes,
    required String mime,
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
          DebugLog.instance.log('IMG',
              'sendImage: malformed pubkey hex for $chatId: $e');
        }
      }
    }
    if (peerPub == null || canonicalId == null) {
      throw StateError('cannot send image: no recipient pubkey for $chatId');
    }

    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: canonicalId,
      text: mime,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
      kind: MessageKind.image,
      imagePath: cachedPath,
      imageMime: mime,
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);
    if (chatId != canonicalId) {
      messages.append(chatId, msg);
    }

    try {
      final imageId = ImageChunk.newImageId();
      final total = (bytes.length + ImageChunk.maxDataBytes - 1) ~/
          ImageChunk.maxDataBytes;
      if (total > 0xFFFF) {
        throw StateError('image too large: $total chunks > 65535 cap');
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
        bytes: bytes,
        myHash: myHash,
        peerHash: peerHash,
        peerPub: peerPub,
        session: session,
        senderIdentityPub: fs?.identityPub,
        senderEphemeralPub: fs?.ephemeralPub,
      );
      if (fs != null) {
        DebugLog.instance.log('CRYPTO',
            'sendImage: forward-secret (X3DH) media to $canonicalId');
      }
      for (var i = 0; i < total; i++) {
        final start = i * ImageChunk.maxDataBytes;
        final end = (start + ImageChunk.maxDataBytes).clamp(0, bytes.length);
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
          msgId: TransportEnvelope.newMsgId(),
          ttl: TransportEnvelope.defaultTtl,
          body: body,
        );
        _dedup.acceptEnvelope(env);
        final frameBytes = Frame(
          type: FrameType.transport,
          payload: env.encode(),
        ).encode();

        // Direct session preferred, mesh fan-out otherwise.
        final transportId = session?.peerId;
        if (transportId != null) {
          final client = _clients[transportId];
          if (client != null && client.isConnected) {
            await client.writeOutbound(frameBytes);
          } else {
            final ok = await _ref
                .read(blePeripheralProvider)
                .notifyInbound(frameBytes);
            if (!ok) {
              DebugLog.instance.log('IMG',
                  'chunk $i/$total notify returned false — link congested?');
              throw StateError('notify failed on image chunk $i/$total');
            }
          }
        } else {
          final fanout =
              await _fanoutAllLinks(frameBytes, excludePeerId: null);
          if (fanout == 0) {
            throw StateError('no active mesh links for image chunk $i/$total');
          }
        }
        // Tiny pacing gap. Some Android BLE stacks lose notify packets when
        // a fast sender outpaces the receiver's read loop. 15ms is below
        // human perception in aggregate (~5s for a 300-chunk image) and
        // well above the worst-case per-chunk turn-around on tested
        // hardware.
        if (i + 1 < total) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
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
          DebugLog.instance.log('VOICE',
              'sendAudio: malformed pubkey hex for $chatId: $e');
        }
      }
    }
    if (peerPub == null || canonicalId == null) {
      throw StateError('cannot send audio: no recipient pubkey for $chatId');
    }

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
    );
    final messages = _ref.read(messagesControllerProvider.notifier);
    messages.append(canonicalId, msg);
    if (chatId != canonicalId) {
      messages.append(chatId, msg);
    }

    try {
      final audioId = AudioChunk.newAudioId();
      final total = (bytes.length + AudioChunk.maxDataBytes - 1) ~/
          AudioChunk.maxDataBytes;
      if (total > 0xFFFF) {
        throw StateError('audio too large: $total chunks > 65535 cap');
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
        senderIdentityPub: fs?.identityPub,
        senderEphemeralPub: fs?.ephemeralPub,
      );
      if (fs != null) {
        DebugLog.instance.log('CRYPTO',
            'sendAudio: forward-secret (X3DH) media to $canonicalId');
      }
      for (var i = 0; i < total; i++) {
        final start = i * AudioChunk.maxDataBytes;
        final end =
            (start + AudioChunk.maxDataBytes).clamp(0, bytes.length);
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
          msgId: TransportEnvelope.newMsgId(),
          ttl: TransportEnvelope.defaultTtl,
          body: body,
        );
        _dedup.acceptEnvelope(env);
        final frameBytes = Frame(
          type: FrameType.transport,
          payload: env.encode(),
        ).encode();

        final transportId = session?.peerId;
        if (transportId != null) {
          final client = _clients[transportId];
          if (client != null && client.isConnected) {
            await client.writeOutbound(frameBytes);
          } else {
            final ok = await _ref
                .read(blePeripheralProvider)
                .notifyInbound(frameBytes);
            if (!ok) {
              DebugLog.instance.log('VOICE',
                  'chunk $i/$total notify returned false');
              throw StateError('notify failed on audio chunk $i/$total');
            }
          }
        } else {
          final fanout =
              await _fanoutAllLinks(frameBytes, excludePeerId: null);
          if (fanout == 0) {
            throw StateError('no active mesh links for audio chunk $i/$total');
          }
        }
        if (i + 1 < total) {
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

  /// Acknowledge every not-yet-acked inbound message in the [canonicalId]
  /// (pubkey-hex) chat as *read*. Called when the user opens / views a chat.
  /// No-op for channels (no per-recipient read state) and when there's
  /// nothing new to ack. Best-effort: a send failure rolls the ack back so
  /// the next view retries.
  Future<void> sendReadReceipts(String canonicalId) async {
    if (canonicalId.startsWith('#')) return;
    final msgs = _ref.read(messagesControllerProvider)[canonicalId];
    if (msgs == null || msgs.isEmpty) return;

    final fresh = <Uint8List>[];
    for (final m in msgs) {
      if (m.isMine) continue;
      final w = m.wireId;
      if (w == null || _sentReadAcks.contains(w)) continue;
      try {
        fresh.add(_hexDecodeBytes(w));
        _sentReadAcks.add(w);
      } catch (_) {/* skip malformed wireId */}
    }
    if (fresh.isEmpty) return;

    final peerPub = _resolvePeerPub(canonicalId);
    if (peerPub == null) return;

    for (var i = 0; i < fresh.length; i += ReadReceipt.maxIdsPerFrame) {
      final end = (i + ReadReceipt.maxIdsPerFrame).clamp(0, fresh.length);
      final slice = fresh.sublist(i, end);
      final receipt =
          ReadReceipt(status: ReceiptStatus.read, msgIds: slice);
      try {
        await _sendControlToPeer(
          canonicalId: canonicalId,
          peerPub: peerPub,
          type: InnerPayloadType.receipt,
          innerBody: receipt.encode(),
        );
      } catch (e) {
        for (final id in slice) {
          _sentReadAcks.remove(TransportEnvelope.hashHex(id));
        }
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
        final msgId = TransportEnvelope.newMsgId();
        final frame = await _buildChannelFrame(
            channel, InnerPayloadType.reaction, body, msgId);
        await _fanoutAllLinks(frame, excludePeerId: null);
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
          TransportEnvelope.newMsgId(),
        );
        await _fanoutAllLinks(frame, excludePeerId: null);
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
          TransportEnvelope.newMsgId(),
        );
        await _fanoutAllLinks(frame, excludePeerId: null);
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
      DebugLog.instance.log('CHAN',
          'drop channel invite from $peerId: not signed');
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
      DebugLog.instance.log('CHAN',
          'drop channel invite from $peerId: malformed ($e)');
      return;
    }
    try {
      final channel = await _ref
          .read(channelControllerProvider.notifier)
          .joinWithKey(invite.name, invite.key);
      DebugLog.instance.log('CHAN',
          'auto-joined ${channel.name} on invite from ${inviter.displayName}');
      if (!AppLifecycle.instance.isViewingChat(channel.name)) {
        unawaited(NotificationService.instance.showMessage(
          threadKey: channel.name,
          title: channel.name,
          body: '${inviter.displayName} added you to this channel',
        ));
      }
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
    final canonicalId = channel.name;
    final msgId = TransportEnvelope.newMsgId();
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
      final frame =
          await _buildChannelFrame(channel, InnerPayloadType.text, inner, msgId);
      final fanout = await _fanoutAllLinks(frame, excludePeerId: null);
      messages.updateStatus(
        canonicalId,
        msg.id,
        fanout > 0 ? MessageStatus.delivered : MessageStatus.sending,
      );
      DebugLog.instance.log('CHAN',
          'channel post to ${channel.name} fanout=$fanout');
    } catch (e, st) {
      debugPrint('sendChannelText failed: $e\n$st');
      messages.updateStatus(canonicalId, msg.id, MessageStatus.failed);
    }
    return msg;
  }

  /// Sign + SealedBox-encrypt a small control payload (read receipt /
  /// reaction) to a single peer and deliver it best-effort (direct session,
  /// else mesh fan-out — no store-and-forward hold; a receipt/reaction that
  /// misses isn't worth persisting). Returns the number of links it went out
  /// on.
  Future<int> _sendControlToPeer({
    required String canonicalId,
    required Uint8List peerPub,
    required InnerPayloadType type,
    required Uint8List innerBody,
  }) async {
    final identity = await _ref.read(identityProvider.future);
    final myHash = await _myPubkeyHash();
    final peerHash = await _peerPubkeyHash(peerPub);
    final msgId = TransportEnvelope.newMsgId();
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
      ttl: TransportEnvelope.defaultTtl,
      body: body,
    );
    _dedup.acceptEnvelope(env);
    final frameBytes =
        Frame(type: FrameType.transport, payload: env.encode()).encode();

    final session = _findSessionByPubkeyHex(canonicalId);
    final transportId = session?.peerId;
    if (transportId != null) {
      final client = _clients[transportId];
      if (client != null && client.isConnected) {
        try {
          await client.writeOutbound(frameBytes);
          return 1;
        } catch (_) {/* fall through to notify / fan-out */}
      }
      try {
        if (await _ref.read(blePeripheralProvider).notifyInbound(frameBytes)) {
          return 1;
        }
      } catch (_) {}
    }
    return _fanoutAllLinks(frameBytes, excludePeerId: null);
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
      ..setRange(ChannelCrypto.tagLen, ChannelCrypto.tagLen + sealed.length,
          sealed);
    final env = TransportEnvelope(
      originPubkeyHash: myHash,
      destPubkeyHash: broadcast,
      msgId: msgId,
      ttl: TransportEnvelope.defaultTtl,
      body: _tagBody(_cipherChannel, channelBody),
    );
    _dedup.acceptEnvelope(env);
    return Frame(type: FrameType.transport, payload: env.encode()).encode();
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

    final blob =
        Uint8List.fromList(channelBody.sublist(ChannelCrypto.tagLen));
    final Uint8List plain;
    try {
      plain = await ChannelCrypto.open(channel.key, blob);
    } catch (e) {
      DebugLog.instance.log('CHAN',
          'drop ${channel.name} frame: decrypt failed (wrong password?)');
      return;
    }

    if (plain.isEmpty || plain[0] != SignedPayload.markerByte) {
      DebugLog.instance.log('CHAN',
          'drop ${channel.name} frame: not author-signed');
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
      DebugLog.instance.log('CHAN',
          'drop ${channel.name} frame: bad signature (${e.message})');
      return;
    }

    try {
      final unpacked = unpackInnerPayload(innerBytes);
      final authorName = _resolveAuthorName(senderEdPub);
      final reactorId = _hexOf(senderEdPub).substring(0, 16);
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
          );
          _ref
              .read(messagesControllerProvider.notifier)
              .append(channel.name, message);
          _notifyChannel(
              channel: channel, authorName: authorName, message: message);
        case InnerPayloadType.reaction:
          final rx = Reaction.decode(unpacked.body);
          _applyReactionToBuckets([channel.name],
              rx: rx, reactorId: reactorId);

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

        case InnerPayloadType.receipt:
        case InnerPayloadType.channelInvite:
        case InnerPayloadType.imageChunk:
        case InnerPayloadType.audioChunk:
        case InnerPayloadType.mediaManifest:
          // Not carried in channels — ignore. (An invite is addressed to one
          // peer; broadcasting one to the channel would be circular.)
          break;
      }
    } catch (e) {
      DebugLog.instance.log('CHAN',
          'drop ${channel.name} frame: malformed inner ($e)');
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
    unawaited(NotificationService.instance.showMessage(
      threadKey: channel.name,
      title: channel.name,
      body: '$authorName: ${message.text}',
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

  Future<void> _handleInboundBytes(String peerId, Uint8List bytes) async {
    final Frame frame;
    try {
      frame = Frame.decode(bytes);
    } catch (e) {
      DebugLog.instance.log('NOISE', 'drop malformed frame from $peerId: $e');
      return;
    }
    await _handleFrame(peerId, frame, fromCentral: false);
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
      DebugLog.instance.log('NOISE',
          'RX ${frame.type.name} from $peerId (${frame.payload.length}B, '
          '${fromCentral ? "peripheral side" : "central side"})');
    }

    final manager = _ref.read(chatSessionManagerProvider.notifier);

    switch (frame.type) {
      case FrameType.noiseHandshake1:
        // Only valid when we're acting as responder (peripheral side received
        // a fresh HS1 from a central we don't yet have a session with).
        _armHandshakeWatchdog(peerId);
        final session = await manager.startResponder(peerId);
        final reply = await session.handleHandshakeFrame(frame);
        manager.touch(peerId);
        if (session.isEstablished) {
          _clearHandshakeWatchdog(peerId);
          _registerKnownPeer(session);
        }
        if (reply != null) await _writeBack(peerId, reply, fromCentral: fromCentral);

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
        if (reply != null) await _writeBack(peerId, reply, fromCentral: fromCentral);

      case FrameType.transport:
        await _handleTransportFrame(peerId, frame);

      case FrameType.peerAnnouncement:
        await _handlePeerAnnouncementFrame(peerId, frame);

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
      DebugLog.instance.log('NOISE',
          'drop transport from $peerId: malformed envelope ($e)');
      return;
    }
    // Suppressed by default — see _handleFrame above. The reassembler logs
    // sampled progress, and any decode/decrypt/sig failures still produce
    // their own log lines below.

    // Dedup: drop frames we've already seen via another path. Keyed on the
    // (origin, msgId) pair which is stable regardless of which relay
    // delivered the copy.
    if (!_dedup.acceptEnvelope(env)) {
      DebugLog.instance.log('NOISE', 'drop transport: duplicate (origin+msgId)');
      return;
    }

    final myHash = await _myPubkeyHash();
    final isForMe = _bytesEqual(env.destPubkeyHash, myHash);
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
        DebugLog.instance.log('MESH',
            'transport not for me — forwarded + held for dest '
            '(${_store.size} frame(s) across ${_store.destinationCount} dest)');
      } else {
        DebugLog.instance.log('MESH',
            'broadcast not for me, forwarded only (no hold)');
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
        DebugLog.instance.log('CRYPTO', 'drop transport from $peerId: empty body');
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
          DebugLog.instance.log('CRYPTO', 'drop FS from $peerId: malformed ($e)');
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
          DebugLog.instance.log('CRYPTO', 'FS (X3DH) body decrypted from $peerId');
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
          DebugLog.instance.log('NOISE', 'SealedBox open FAILED for $peerId: $e');
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
          DebugLog.instance.log('CRYPTO',
              'drop FS media chunk from $peerId: malformed ($e)');
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
          DebugLog.instance.log('CRYPTO',
              'FS media chunk decrypt FAILED from $peerId: $e');
          return;
        }
      } else {
        DebugLog.instance.log('CRYPTO',
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
          DebugLog.instance.log('CRYPTO',
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
          DebugLog.instance.log('CRYPTO',
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
          DebugLog.instance.log('CRYPTO',
              'compact-signed FS body verified from $peerId');
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
      final senderPub = session?.remoteStaticPublicKey;

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
          DebugLog.instance.log('NOISE',
              'RX text from $peerId (${plaintext.length} chars)');
          final message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: plaintext,
            sentAt: DateTime.now(),
            isMine: false,
            forwardSecret: cipher == _cipherX3dh,
            wireId: TransportEnvelope.hashHex(env.msgId),
          );
          _appendToAllSessionsForSamePeer(senderPub,
              fallbackPeerId: peerId, message: message);

        case InnerPayloadType.receipt:
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
      DebugLog.instance.log('VOICE',
          'drop audio chunk from $peerId: malformed ($e)');
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
      DebugLog.instance.log('IMG',
          'drop image chunk from $peerId: malformed ($e)');
      return;
    }
    final done = _imageReassembler.ingest(chunk);
    if (done == null) return;
    await _finalizeMedia(
      peerId: peerId,
      senderPub: senderPub,
      kind: MediaKind.image,
      mediaId: done.imageId,
      bytes: done.bytes,
      mime: done.mime,
      durationMs: 0,
    );
  }

  /// Decode + retain a signed media manifest. If the chunks have already
  /// fully arrived (orphan path) we verify SHA-256 here and emit the
  /// message immediately; otherwise we stash the manifest for the
  /// finalisation step in [_finalizeMedia].
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
      DebugLog.instance.log('CRYPTO',
          'drop media manifest from $peerId: malformed ($e)');
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
      DebugLog.instance.log('CRYPTO',
          'late manifest matched orphan media $key — verifying');
      await _verifyAndEmit(
        peerId: peerId,
        senderPub: senderPub,
        manifest: manifest,
        bytes: orphan.bytes,
      );
      return;
    }
    _pendingManifests[key] = _ManifestEntry(
      manifest: manifest,
      arrivedAt: DateTime.now(),
      peerId: peerId,
      senderPub: senderPub,
    );
    DebugLog.instance.log('CRYPTO',
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
  /// for a mediaId have fully reassembled. If we already have a signed
  /// manifest for that id, verify SHA-256 + emit; otherwise park the
  /// bytes as an orphan until the manifest catches up.
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
    if (pending != null) {
      await _verifyAndEmit(
        peerId: pending.peerId,
        senderPub: pending.senderPub,
        manifest: pending.manifest,
        bytes: bytes,
      );
      return;
    }
    DebugLog.instance.log('CRYPTO',
        'media $key assembled before manifest — parking as orphan');
    _orphanedMedia[key] = _OrphanMedia(
      bytes: bytes,
      mime: mime,
      kind: kind,
      durationMs: durationMs,
      arrivedAt: DateTime.now(),
      peerId: peerId,
      senderPub: senderPub,
    );
  }

  Future<void> _verifyAndEmit({
    required String peerId,
    required Uint8List? senderPub,
    required MediaManifest manifest,
    required Uint8List bytes,
  }) async {
    final digest = await Sha256().hash(bytes);
    final actual = Uint8List.fromList(digest.bytes);
    if (!_bytesEqual(actual, manifest.sha256)) {
      DebugLog.instance.log('CRYPTO',
          'DROP media ${_hexOf(manifest.mediaId)}: '
          'sha256 mismatch (manifest says ${_hexOf(manifest.sha256).substring(0, 8)}…, '
          'assembled ${_hexOf(actual).substring(0, 8)}…)');
      return;
    }
    DebugLog.instance.log('CRYPTO',
        'media ${_hexOf(manifest.mediaId)} sha256 OK '
        '(${bytes.length}B, ${manifest.kind.name})');
    try {
      final Message message;
      switch (manifest.kind) {
        case MediaKind.image:
          final path = await ImageReassembler.persistToCache(
            imageId: manifest.mediaId,
            bytes: bytes,
            mime: manifest.mime,
          );
          message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: manifest.mime,
            sentAt: DateTime.now(),
            isMine: false,
            kind: MessageKind.image,
            imagePath: path,
            imageMime: manifest.mime,
          );

        case MediaKind.audio:
          final path = await AudioReassembler.persistToCache(
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
          );
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
        !_pendingManifests.containsKey(id) && !_pendingFsChunks.containsKey(id));
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
    required Uint8List bytes,
    required Uint8List myHash,
    required Uint8List peerHash,
    required Uint8List peerPub,
    required ChatSession? session,
    Uint8List? senderIdentityPub,
    Uint8List? senderEphemeralPub,
  }) async {
    final identity = await _ref.read(identityProvider.future);
    final digest = await Sha256().hash(bytes);
    final manifest = MediaManifest(
      mediaId: mediaId,
      kind: kind,
      total: total,
      mime: mime,
      durationMs: durationMs,
      sha256: Uint8List.fromList(digest.bytes),
      senderIdentityPub: senderIdentityPub,
      senderEphemeralPub: senderEphemeralPub,
    );
    final inner = packInnerPayload(
      InnerPayloadType.mediaManifest,
      manifest.encode(),
    );
    final msgId = TransportEnvelope.newMsgId();
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
      ttl: TransportEnvelope.defaultTtl,
      body: body,
    );
    _dedup.acceptEnvelope(env);
    final frameBytes = Frame(
      type: FrameType.transport,
      payload: env.encode(),
    ).encode();
    final transportId = session?.peerId;
    if (transportId != null) {
      final client = _clients[transportId];
      if (client != null && client.isConnected) {
        await client.writeOutbound(frameBytes);
        return;
      }
      final ok =
          await _ref.read(blePeripheralProvider).notifyInbound(frameBytes);
      if (ok) return;
      throw StateError('manifest notify rejected');
    }
    final fanout = await _fanoutAllLinks(frameBytes, excludePeerId: null);
    if (fanout == 0) {
      throw StateError('no active mesh links for media manifest');
    }
  }

  /// Peer-announcement RX: unwrap envelope, dedup, verify the inner
  /// `PeerAnnouncement` signature and upsert the (x25519, ed25519, name)
  /// triplet into the roster. Announcement signatures defend against an
  /// attacker on the mesh injecting fake ed25519 pubkeys to break later
  /// per-message signature verification.
  Future<void> _handlePeerAnnouncementFrame(String peerId, Frame frame) async {
    final TransportEnvelope env;
    try {
      env = TransportEnvelope.decode(frame.payload);
    } catch (e) {
      DebugLog.instance.log('MESH',
          'drop announce from $peerId: malformed envelope ($e)');
      return;
    }
    if (!_dedup.acceptEnvelope(env)) {
      DebugLog.instance.log('MESH', 'drop announce: duplicate');
      return;
    }
    final PeerAnnouncement ann;
    try {
      ann = await PeerAnnouncement.verifyAndDecode(env.body);
    } catch (e) {
      DebugLog.instance.log('MESH',
          'drop announce from $peerId: bad signature / format ($e)');
      return;
    }
    // Skip our own announcement bouncing back to us through a relay.
    final myHash = await _myPubkeyHash();
    if (_bytesEqual(env.originPubkeyHash, myHash)) {
      DebugLog.instance.log('MESH', 'drop announce: it is mine');
      return;
    }
    final pubkeyHex = _hexOf(ann.pubkey);
    _ref.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: pubkeyHex,
          displayName: ann.nickname,
          signPublicKey: ann.signPubkey,
          signedPrekeyPub: ann.signedPrekeyPub,
        );
    DebugLog.instance.log('MESH',
        'registered SIGNED announce: "${ann.nickname}" ($pubkeyHex) via $peerId '
        '(+ signed prekey)');

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
    final relayed = env.decrementTtl();
    if (relayed.ttl <= 0) {
      DebugLog.instance.log('MESH',
          'not forwarding ${outerType.name}: ttl exhausted');
      return;
    }
    final bytes = Frame(type: outerType, payload: relayed.encode()).encode();
    final fanout = await _fanoutAllLinks(bytes, excludePeerId: excludePeerId);
    DebugLog.instance.log('MESH',
        'relayed ${outerType.name} ttl=${relayed.ttl} fanout=$fanout');
  }

  /// Writes [bytes] (a fully-encoded frame) onto every active link except
  /// [excludePeerId]. Peripheral notify is always included (it reaches all
  /// subscribed centrals — receiver dedup handles any echo). Returns the
  /// number of links the frame was emitted onto.
  Future<int> _fanoutAllLinks(
    Uint8List bytes, {
    required String? excludePeerId,
  }) async {
    var fanout = 0;
    for (final entry in _clients.entries) {
      if (entry.key == excludePeerId) continue;
      if (!entry.value.isConnected) continue;
      try {
        await entry.value.writeOutbound(bytes);
        fanout++;
      } catch (e) {
        DebugLog.instance.log('MESH', 'fanout client write failed: $e');
      }
    }
    try {
      final ok = await _ref.read(blePeripheralProvider).notifyInbound(bytes);
      if (ok) fanout++;
    } catch (e) {
      DebugLog.instance.log('MESH', 'fanout notify failed: $e');
    }
    return fanout;
  }

  /// Replay-window gate shared by the full + compact signed paths. The
  /// signed timestamp can't be refreshed by a relay without the sender's
  /// Ed25519 key, so a captured frame re-injected after dedup expiry still
  /// carries its original send time. Returns false (and logs) when the
  /// frame is too old or implausibly far in the future.
  bool _freshEnough(int timestampMs, String peerId) {
    final skewMs = DateTime.now().millisecondsSinceEpoch - timestampMs;
    if (skewMs > _replayMaxAgeMs) {
      DebugLog.instance.log('CRYPTO',
          'drop signed body from $peerId: stale '
          '(${(skewMs / 1000).round()}s old > replay window)');
      return false;
    }
    if (skewMs < -_replayMaxFutureMs) {
      DebugLog.instance.log('CRYPTO',
          'drop signed body from $peerId: timestamp '
          '${(-skewMs / 1000).round()}s in the future (clock skew?)');
      return false;
    }
    return true;
  }

  /// Returns the cached Ed25519 verifying key for the peer whose X25519
  /// pubkey hashes to [originPubkeyHash], or null if we've never seen a
  /// signed announcement from them. Linear-scan over the KnownPeers
  /// roster; for the current scale (<<1000 peers) this is fine.
  Future<Uint8List?> _expectedEdPubFor(Uint8List originPubkeyHash) async {
    final known = _ref.read(knownPeersControllerProvider);
    for (final p in known.values) {
      final pub = p.signPublicKey;
      if (pub == null) continue;
      try {
        final xBytes = _hexDecodeBytes(p.pubkeyHex);
        final h = await _peerPubkeyHash(xBytes);
        if (_bytesEqual(h, originPubkeyHash)) {
          return pub;
        }
      } catch (_) {
        // ignore malformed entries
      }
    }
    return null;
  }

  /// Caches a fresh (originHash → ed pub) binding learned from a
  /// successful TOFU-verified message. Bootstraps strict-mode
  /// verification for subsequent messages from the same peer.
  Future<void> _maybeCacheSignerForOrigin({
    required Uint8List originHash,
    required Uint8List edPub,
  }) async {
    final known = _ref.read(knownPeersControllerProvider);
    for (final p in known.values) {
      try {
        final xBytes = _hexDecodeBytes(p.pubkeyHex);
        final h = await _peerPubkeyHash(xBytes);
        if (!_bytesEqual(h, originHash)) continue;
        if (p.signPublicKey != null) return; // already cached
        _ref.read(knownPeersControllerProvider.notifier).upsert(
              pubkeyHex: p.pubkeyHex,
              displayName: p.displayName,
              signPublicKey: edPub,
            );
        DebugLog.instance.log('CRYPTO',
            'cached signer for ${p.pubkeyHex} via TOFU');
        return;
      } catch (_) {
        // ignore
      }
    }
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

  /// Build and send one [PeerAnnouncement] across every active client and the
  /// peripheral notify pipe. Safe to call before any link exists — the
  /// individual sends just no-op.
  Future<void> _broadcastAnnouncement() async {
    try {
      final identity = await _ref.read(identityProvider.future);
      final nickname = _ref.read(nicknameControllerProvider);
      final prekeys = _ref.read(prekeyServiceProvider);
      await prekeys.ensureInitialized();
      final ann = PeerAnnouncement(
        pubkey: Uint8List.fromList(identity.publicKey),
        signPubkey: identity.signPublicKey,
        signedPrekeyPub: prekeys.signedPrekeyPub,
        nickname: nickname,
      );
      final signedBody = await ann.sign(identity.asSignKeyPair());
      final env = TransportEnvelope(
        originPubkeyHash: await _myPubkeyHash(),
        destPubkeyHash: TransportEnvelope.broadcastDest(),
        msgId: TransportEnvelope.newMsgId(),
        ttl: TransportEnvelope.defaultTtl,
        body: signedBody,
      );
      final frame = Frame(
        type: FrameType.peerAnnouncement,
        payload: env.encode(),
      );
      // Mark our own announcement in the dedup cache so a reflected copy
      // bouncing back from a relay can't accidentally pass the broadcast
      // self-skip check (defense-in-depth).
      _dedup.acceptEnvelope(env);

      final fanout =
          await _fanoutAllLinks(frame.encode(), excludePeerId: null);
      if (fanout > 0) {
        DebugLog.instance.log('MESH',
            'announced "${ann.nickname}" on $fanout link(s)');
      }
    } catch (e, st) {
      debugPrint('broadcastAnnouncement failed: $e\n$st');
    }
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
    // Canonical key (lives forever, used by chats list).
    messages.append(pubkeyHex, message);

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
  void _notifyIncoming({required String canonicalId, required Message message}) {
    if (message.isMine) return;
    // Suppress only when the user is actively reading THIS chat. A message
    // from someone else (or while on the chats list / nearby / backgrounded)
    // still pops a notification.
    if (AppLifecycle.instance.isViewingChat(canonicalId)) return;
    final known = _ref.read(knownPeersControllerProvider)[canonicalId];
    final name = (known?.displayName.isNotEmpty ?? false)
        ? known!.displayName
        : 'New message';
    final String preview;
    switch (message.kind) {
      case MessageKind.image:
        preview = '📷 Photo';
      case MessageKind.audio:
        preview = '🎤 Voice message';
      case MessageKind.text:
        preview = message.text;
    }
    unawaited(NotificationService.instance.showMessage(
      threadKey: canonicalId,
      title: name,
      body: preview,
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
    DebugLog.instance.log('NOISE',
        'registered known peer: ${session.peerLabel} ($pubkeyHex)');
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
    final Uint8List hash;
    try {
      hash = await _peerPubkeyHash(pub);
    } catch (_) {
      return;
    }
    final pending = _store.drainFor(hash);
    if (pending.isEmpty) return;
    _scheduleRelayPersist(); // drain mutated the buffer
    DebugLog.instance.log('MESH',
        'store-and-forward: delivering ${pending.length} held frame(s) '
        'to ${session.peerId}');
    final client = _clients[session.peerId];
    for (final bytes in pending) {
      var sent = false;
      try {
        if (client != null && client.isConnected) {
          await client.writeOutbound(bytes);
          sent = true;
        } else {
          sent = await _ref.read(blePeripheralProvider).notifyInbound(bytes);
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
      messages.updateStatus(ref.canonicalId, ref.messageId,
          MessageStatus.delivered);
      if (ref.chatId != ref.canonicalId) {
        messages.updateStatus(ref.chatId, ref.messageId,
            MessageStatus.delivered);
      }
      DebugLog.instance.log('MESH',
          'outbox delivered: ${ref.messageId} → ${ref.canonicalId}');
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
        DebugLog.instance.log('MESH',
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
        DebugLog.instance.log('NOISE', 'no client for $peerId, cannot write back');
        return;
      }
      await c.writeOutbound(bytes);
    }
  }

  // -------------------- peripheral event hookup --------------------

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
        DebugLog.instance.log('BLE-PERIPH',
            'central connected: ${event.centralId}');
        _ref
            .read(peripheralControllerProvider.notifier)
            .onCentralConnected(event.centralId);
      } else if (event is PeripheralWrite) {
        DebugLog.instance.log('BLE-PERIPH',
            'write from ${event.centralId} (${event.data.length}B)');
        // A central has written to our outbound characteristic — treat it as
        // an inbound frame for the responder side.
        final Frame frame;
        try {
          frame = Frame.decode(event.data);
        } catch (e) {
          DebugLog.instance.log('BLE-PERIPH', 'decode failed: $e');
          return;
        }
        await _handleFrame(event.centralId, frame, fromCentral: true);
      } else if (event is PeripheralCentralDisconnected) {
        DebugLog.instance.log('BLE-PERIPH',
            'central disconnected: ${event.centralId}');
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
    _announcementTimer?.cancel();
    _announcementTimer = null;
    // Flush any pending buffer write synchronously so a held frame isn't
    // lost if we're disposed inside the debounce window.
    _relayPersistTimer?.cancel();
    _relayPersistTimer = null;
    await _persistRelayBuffer();
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

/// One signed media manifest awaiting its chunks. Holds enough context
/// to attribute the resulting Message to the right peer once the bytes
/// have caught up.
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

class _ManifestEntry {
  _ManifestEntry({
    required this.manifest,
    required this.arrivedAt,
    required this.peerId,
    required this.senderPub,
  });
  final MediaManifest manifest;
  final DateTime arrivedAt;
  final String peerId;
  final Uint8List? senderPub;
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
