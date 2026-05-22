import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'package:cryptography/cryptography.dart';

import '../../features/chat/data/messages_controller.dart';
import '../../features/chat/models/message.dart';
import '../../features/peers/data/known_peers_controller.dart';
import '../../features/peers/data/peripheral_controller.dart';
import '../ble/ble_peripheral.dart';
import '../crypto/fs_message.dart';
import '../crypto/identity_service.dart';
import '../crypto/prekey_service.dart';
import '../crypto/sealed_box.dart';
import '../crypto/signed_payload.dart';
import '../crypto/x3dh.dart';
import '../identity/nickname_controller.dart';
import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
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
      _clients.remove(peerId);
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

    final msg = Message(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      chatId: canonicalId,
      text: text,
      sentAt: DateTime.now(),
      isMine: true,
      status: MessageStatus.sending,
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
      final msgId = TransportEnvelope.newMsgId();
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
      var deliveredVia = 0;
      if (transportId != null) {
        final client = _clients[transportId];
        if (client != null && client.isConnected) {
          await client.writeOutbound(outboundFrame.encode());
          deliveredVia = 1;
        } else {
          // Session exists but central side is gone — push via peripheral
          // notify (matches pre-mesh behaviour).
          final ok = await _ref
              .read(blePeripheralProvider)
              .notifyInbound(outboundFrame.encode());
          if (ok) {
            deliveredVia = 1;
          } else {
            DebugLog.instance.log('NOISE',
                'text send: notify returned false (no subscriber?), falling back to fan-out');
            // Last-ditch fan-out so the message still has a chance to reach
            // its destination via a relay.
            deliveredVia = await _fanoutAllLinks(
              outboundFrame.encode(),
              excludePeerId: null,
            );
            if (deliveredVia == 0) {
              throw StateError(
                  'send failed: notify rejected and no mesh links available');
            }
          }
        }
      } else {
        // No direct session for this recipient — broadcast onto every open
        // link and let the mesh route it. Receivers dedup on (origin, msgId).
        deliveredVia = await _fanoutAllLinks(
          outboundFrame.encode(),
          excludePeerId: null,
        );
        if (deliveredVia == 0) {
          throw StateError('no active mesh links to relay through');
        }
      }
      messages.updateStatus(canonicalId, msg.id, MessageStatus.delivered);
      if (chatId != canonicalId) {
        messages.updateStatus(chatId, msg.id, MessageStatus.delivered);
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
      );
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
        final body =
            _tagBody(_cipherSealedBox, await SealedBox.seal(inner, peerPub));
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
      );
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
        // overflow MTU). Integrity rides on SealedBox AEAD; sender identity
        // rides on the signed announcement chain.
        final body =
            _tagBody(_cipherSealedBox, await SealedBox.seal(inner, peerPub));
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
    }
    return msg;
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
      // First byte = cipher tag (0x01 SealedBox, 0x02 X3DH forward-secret).
      final cipher = env.body[0];
      final cipherBody = Uint8List.sublistView(env.body, 1);

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
          );
          _appendToAllSessionsForSamePeer(senderPub,
              fallbackPeerId: peerId, message: message);

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
        '(${manifest.kind.name} total=${manifest.total})');
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
      try {
        if (client != null && client.isConnected) {
          await client.writeOutbound(bytes);
        } else {
          await _ref.read(blePeripheralProvider).notifyInbound(bytes);
        }
      } catch (e) {
        DebugLog.instance.log('MESH',
            'store-and-forward delivery failed for ${session.peerId}: $e');
      }
      // Pace like the chunked-media path so we don't overrun a cheap stack.
      await Future<void>.delayed(const Duration(milliseconds: 20));
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

  /// Drops every frame held in the store-and-forward buffer. Called by
  /// Emergency Wipe — although these frames are opaque (encrypted to other
  /// peers), a panic wipe should leave nothing behind.
  void clearRelayBuffer() {
    _store.clear();
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
