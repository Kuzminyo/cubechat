import 'dart:async';
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
import '../identity/nickname_controller.dart';
import '../util/debug_log.dart';
import 'announcement.dart';
import 'ble_gatt_client.dart';
import 'chat_session.dart';
import 'chat_session_manager.dart';
import 'dedup_cache.dart';
import 'envelope.dart';
import 'frame.dart';

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
  /// main Chats list). We resolve to a live, established session by
  /// searching first by transport id, then by pubkeyHex.
  Future<Message> sendText(String chatId, String text) async {
    final manager = _ref.read(chatSessionManagerProvider.notifier);

    ChatSession? session = manager.sessionFor(chatId);
    session ??= _findSessionByPubkeyHex(chatId);

    if (session == null || !session.isEstablished) {
      throw StateError('cannot send: no established session for $chatId');
    }

    // Canonical key for storage: pubkeyHex of the authenticated peer.
    final canonicalId = session.remotePubkeyHex ?? chatId;

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
      final inner = await session.encryptText(text);
      // Wrap the encrypted bytes in a mesh envelope so relays (M3.E) can
      // route this frame even without knowing the body. For direct-link
      // chats this just adds a 33-byte header on top of the Noise ciphertext.
      final peerPub = session.remoteStaticPublicKey;
      if (peerPub == null) {
        throw StateError('session has no remote pubkey, cannot address envelope');
      }
      final myHash = await _myPubkeyHash();
      final peerHash = await _peerPubkeyHash(peerPub);
      final envelope = TransportEnvelope(
        originPubkeyHash: myHash,
        destPubkeyHash: peerHash,
        msgId: TransportEnvelope.newMsgId(),
        ttl: TransportEnvelope.defaultTtl,
        body: inner.payload,
      );
      final outboundFrame = Frame(
        type: FrameType.transport,
        payload: envelope.encode(),
      );

      final transportId = session.peerId;
      final client = _clients[transportId];
      if (client != null && client.isConnected) {
        await client.writeOutbound(outboundFrame.encode());
      } else {
        final ok = await _ref.read(blePeripheralProvider).notifyInbound(outboundFrame.encode());
        if (!ok) {
          throw StateError('peripheral notify returned false');
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
    final addressedToMe = env.isBroadcast || _bytesEqual(env.destPubkeyHash, myHash);

    if (!addressedToMe) {
      // Forwarding lands in M3.E. For now just log and drop.
      DebugLog.instance.log('NOISE',
          'not for me, dropping (relay forwarding lands in M3.E)');
      return;
    }

    // Addressed to us — decrypt the body via the direct-link Noise session
    // we share with the immediate sender. SealedBox swap-in is M3.D.
    final manager = _ref.read(chatSessionManagerProvider.notifier);
    final session = manager.sessionFor(peerId);
    if (session == null || !session.isEstablished) {
      DebugLog.instance.log('NOISE',
          'drop transport: no established session for $peerId');
      return;
    }
    try {
      // Reconstruct the inner Noise frame so the existing decryptText
      // path can stay as-is. Its `.payload` is what we encrypted on the
      // sender side.
      final innerFrame = Frame(type: FrameType.transport, payload: env.body);
      final plaintext = await session.decryptText(innerFrame);
      DebugLog.instance.log('NOISE',
          'decrypt OK from $peerId, ${plaintext.length} chars');
      final message = Message(
        id: 'm${DateTime.now().microsecondsSinceEpoch}',
        chatId: peerId,
        text: plaintext,
        sentAt: DateTime.now(),
        isMine: false,
      );
      _appendToAllSessionsForSamePeer(session.remoteStaticPublicKey,
          fallbackPeerId: peerId, message: message);
    } catch (e, st) {
      DebugLog.instance.log('NOISE', 'decrypt FAILED for $peerId: $e');
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

      final bytes = frame.encode();
      var fanout = 0;
      for (final client in _clients.values) {
        if (!client.isConnected) continue;
        try {
          await client.writeOutbound(bytes);
          fanout++;
        } catch (e) {
          DebugLog.instance.log('MESH', 'announce write failed: $e');
        }
      }
      // Also push via peripheral notify so connected centrals see it.
      try {
        final ok = await _ref.read(blePeripheralProvider).notifyInbound(bytes);
        if (ok) fanout++;
      } catch (e) {
        DebugLog.instance.log('MESH', 'announce notify failed: $e');
      }
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
