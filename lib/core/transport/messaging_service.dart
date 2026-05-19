import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:cryptography/cryptography.dart';

import '../../features/chat/data/messages_controller.dart';
import '../../features/chat/models/message.dart';
import '../../features/peers/data/known_peers_controller.dart';
import '../../features/peers/data/peripheral_controller.dart';
import '../ble/ble_peripheral.dart';
import '../crypto/identity_service.dart';
import '../crypto/sealed_box.dart';
import '../identity/nickname_controller.dart';
import '../util/debug_log.dart';
import 'announcement.dart';
import 'ble_gatt_client.dart';
import 'chat_session.dart';
import 'chat_session_manager.dart';
import 'dedup_cache.dart';
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
  }

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
  /// (origin, msgId).
  final DedupCache _dedup = DedupCache();

  /// Multi-chunk image reassembly buffer (M5.4). Each incoming image stream
  /// is keyed by its 16-byte imageId; finished images get written to the
  /// app cache directory and surfaced as Message.kind == image.
  final ImageReassembler _imageReassembler = ImageReassembler();

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
      // M3.D + M5.4: SealedBox-encrypt a tagged inner payload. The tag
      // byte tells the receiver whether to decode as UTF-8 text or as an
      // image chunk. Wire layout under the SealedBox:
      //   [0x10][utf8(text)]
      final inner = packInnerPayload(
        InnerPayloadType.text,
        Uint8List.fromList(utf8.encode(text)),
      );
      final body = await SealedBox.seal(inner, peerPub);
      final myHash = await _myPubkeyHash();
      final peerHash = await _peerPubkeyHash(peerPub);
      final envelope = TransportEnvelope(
        originPubkeyHash: myHash,
        destPubkeyHash: peerHash,
        msgId: TransportEnvelope.newMsgId(),
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
          if (ok) deliveredVia = 1;
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
        final body = await SealedBox.seal(inner, peerPub);
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
            await _ref.read(blePeripheralProvider).notifyInbound(frameBytes);
          }
        } else {
          final fanout = await _fanoutAllLinks(frameBytes, excludePeerId: null);
          if (fanout == 0) {
            throw StateError('no active mesh links for image chunk $i/$total');
          }
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
    DebugLog.instance.log('NOISE',
        'RX ${frame.type.name} from $peerId (${frame.payload.length}B, '
        '${fromCentral ? "peripheral side" : "central side"})');

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
    DebugLog.instance.log('NOISE',
        'envelope from origin=${TransportEnvelope.hashHex(env.originPubkeyHash)} '
        'dest=${TransportEnvelope.hashHex(env.destPubkeyHash)} '
        'ttl=${env.ttl} msgId=${env.msgIdHex().substring(0, 8)}…');

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
      DebugLog.instance.log('MESH',
          'transport not for me, forwarded only (no decrypt)');
      return;
    }

    // Addressed to us — open the SealedBox body with our long-term private
    // key. Note: SealedBox is anonymous — the sender's identity comes from
    // env.originPubkeyHash and is unauthenticated. For now we cross-check
    // against the immediate-link Noise session's remote pubkey when one
    // exists; multi-hop senders are taken on faith pending inner signatures.
    try {
      final identity = await _ref.read(identityProvider.future);
      final innerBytes = await SealedBox.open(
        env.body,
        recipientKeyPair: identity.asKeyPair(),
        recipientPubkey: identity.publicKey,
      );
      final unpacked = unpackInnerPayload(innerBytes);
      final manager = _ref.read(chatSessionManagerProvider.notifier);
      final session = manager.sessionFor(peerId);
      final senderPub = session?.remoteStaticPublicKey;

      switch (unpacked.type) {
        case InnerPayloadType.text:
          final plaintext =
              utf8.decode(unpacked.body, allowMalformed: true);
          DebugLog.instance.log('NOISE',
              'SealedBox open OK (text) from $peerId, ${plaintext.length} chars');
          final message = Message(
            id: 'm${DateTime.now().microsecondsSinceEpoch}',
            chatId: peerId,
            text: plaintext,
            sentAt: DateTime.now(),
            isMine: false,
          );
          _appendToAllSessionsForSamePeer(senderPub,
              fallbackPeerId: peerId, message: message);

        case InnerPayloadType.imageChunk:
          await _ingestImageChunk(
            peerId: peerId,
            senderPub: senderPub,
            chunkBytes: unpacked.body,
          );
      }
    } catch (e, st) {
      DebugLog.instance.log('NOISE', 'SealedBox open FAILED for $peerId: $e');
      debugPrint('$st');
    }
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
    try {
      final path = await ImageReassembler.persistToCache(
        imageId: done.imageId,
        bytes: done.bytes,
        mime: done.mime,
      );
      DebugLog.instance.log('IMG',
          'reassembled ${done.bytes.length}B from $peerId → $path');
      final message = Message(
        id: 'm${DateTime.now().microsecondsSinceEpoch}',
        chatId: peerId,
        text: done.mime,
        sentAt: DateTime.now(),
        isMine: false,
        kind: MessageKind.image,
        imagePath: path,
        imageMime: done.mime,
      );
      _appendToAllSessionsForSamePeer(senderPub,
          fallbackPeerId: peerId, message: message);
    } catch (e, st) {
      DebugLog.instance.log('IMG', 'persist failed: $e');
      debugPrint('$st');
    }
  }

  /// Peer-announcement RX: unwrap envelope, dedup, decode the inner
  /// `PeerAnnouncement` and upsert the (pubkey, nickname) pair into the
  /// roster. Multi-hop forwarding lands in M3.E — for now we accept and
  /// register even frames addressed to a different peer (broadcast).
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
      ann = PeerAnnouncement.decode(env.body);
    } catch (e) {
      DebugLog.instance.log('MESH',
          'drop announce from $peerId: malformed body ($e)');
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
        );
    DebugLog.instance.log('MESH',
        'registered announce: "${ann.nickname}" ($pubkeyHex) via $peerId');

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
      final ann = PeerAnnouncement(
        pubkey: Uint8List.fromList(identity.publicKey),
        nickname: nickname,
      );
      final env = TransportEnvelope(
        originPubkeyHash: await _myPubkeyHash(),
        destPubkeyHash: TransportEnvelope.broadcastDest(),
        msgId: TransportEnvelope.newMsgId(),
        ttl: TransportEnvelope.defaultTtl,
        body: ann.encode(),
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

  Future<void> dispose() async {
    _announcementTimer?.cancel();
    _announcementTimer = null;
    await _peripheralEventsSub?.cancel();
    for (final t in _handshakeTimers.values) {
      t.cancel();
    }
    _handshakeTimers.clear();
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
