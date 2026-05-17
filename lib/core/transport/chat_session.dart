import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../crypto/identity_keys.dart';
import '../crypto/noise/noise_session.dart';
import 'frame.dart';

/// What state a per-peer chat session is in.
enum ChatSessionStatus {
  /// We discovered the peer but haven't started any cryptographic exchange.
  idle,

  /// We sent message 1 / 3, waiting for the next inbound piece.
  handshakingInitiator,

  /// We received message 1, sent message 2, waiting for message 3.
  handshakingResponder,

  /// Noise XX completed — transport keys ready, sending encrypted bytes.
  established,

  /// Something went wrong (auth fail, MAC mismatch, peer reset).
  failed,
}

/// Bundles a [NoiseSession] with the peer-side bookkeeping the rest of the
/// app needs: who we're talking to, where we are in the handshake, what
/// fingerprint to display in the verification dialog.
class ChatSession {
  ChatSession._({
    required this.peerId,
    required this.peerLabel,
    required this.identity,
    required NoiseSession noise,
    required this.isInitiator,
  })  : _noise = noise,
        _status = isInitiator
            ? ChatSessionStatus.idle
            : ChatSessionStatus.handshakingResponder;

  /// Stable transport-level peer identifier (BLE device id on Android,
  /// CoreBluetooth peer uuid on iOS). NOT the cryptographic identity — the
  /// pubkey only becomes known after the handshake authenticates the peer.
  final String peerId;

  /// Display name for the UI. Initially the advertised BLE name; once the
  /// handshake finishes we can substitute the pubkey fingerprint or a
  /// user-chosen nickname.
  final String peerLabel;

  final IdentityKeys identity;
  final NoiseSession _noise;
  final bool isInitiator;

  ChatSessionStatus _status;
  ChatSessionStatus get status => _status;

  bool get isEstablished => _status == ChatSessionStatus.established;

  Uint8List? get remoteStaticPublicKey => _noise.remoteStaticPublicKey;

  /// Lowercase hex of the remote peer's static pubkey. Stable across BLE
  /// Privacy address rotations — this is the canonical chat identity for
  /// the UI and the message store.
  String? get remotePubkeyHex {
    final pk = remoteStaticPublicKey;
    if (pk == null) return null;
    final sb = StringBuffer();
    for (final b in pk) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// BLAKE2s fingerprint of the remote peer's pubkey (only available after
  /// the handshake has completed).
  Future<String?> remoteFingerprint() => _noise.remoteFingerprint();

  static Future<ChatSession> initiate({
    required String peerId,
    required String peerLabel,
    required IdentityKeys identity,
  }) async {
    final noise = await NoiseSession.initiate(identity);
    return ChatSession._(
      peerId: peerId,
      peerLabel: peerLabel,
      identity: identity,
      noise: noise,
      isInitiator: true,
    );
  }

  static Future<ChatSession> respond({
    required String peerId,
    required String peerLabel,
    required IdentityKeys identity,
  }) async {
    final noise = await NoiseSession.respond(identity);
    return ChatSession._(
      peerId: peerId,
      peerLabel: peerLabel,
      identity: identity,
      noise: noise,
      isInitiator: false,
    );
  }

  /// Produces the next outbound frame in the handshake (whichever message
  /// the pattern is currently expecting from our side). Returns null if it's
  /// not our turn or the handshake is done.
  Future<Frame?> nextHandshakeFrame() async {
    if (_noise.established) return null;

    final FrameType type;
    if (isInitiator && _status == ChatSessionStatus.idle) {
      type = FrameType.noiseHandshake1;
      _status = ChatSessionStatus.handshakingInitiator;
    } else if (!isInitiator && _status == ChatSessionStatus.handshakingResponder) {
      type = FrameType.noiseHandshake2;
    } else if (isInitiator && _status == ChatSessionStatus.handshakingInitiator) {
      type = FrameType.noiseHandshake3;
    } else {
      return null;
    }

    try {
      final payload = await _noise.writeHandshake();
      _noise.promoteIfFinished();
      if (_noise.established) _status = ChatSessionStatus.established;
      return Frame(type: type, payload: payload);
    } catch (e, st) {
      debugPrint('ChatSession.nextHandshakeFrame failed: $e\n$st');
      _status = ChatSessionStatus.failed;
      return null;
    }
  }

  /// Drives the handshake with an inbound frame. Returns the next outbound
  /// frame to send (if any) — for the responder this is HS2 right after HS1,
  /// for the initiator this is HS3 right after HS2.
  Future<Frame?> handleHandshakeFrame(Frame frame) async {
    try {
      await _noise.readHandshake(frame.payload);
      if (_noise.established) {
        _status = ChatSessionStatus.established;
        return null;
      }
      // Drive the next outbound message in the pattern.
      return await nextHandshakeFrame();
    } catch (e, st) {
      debugPrint('ChatSession.handleHandshakeFrame failed: $e\n$st');
      _status = ChatSessionStatus.failed;
      return null;
    }
  }

  /// Encrypts a UTF-8 text message and packages it as a transport frame.
  Future<Frame> encryptText(String text) async {
    if (!isEstablished) {
      throw StateError('encrypt called before handshake completed');
    }
    final plain = Uint8List.fromList(utf8.encode(text));
    final ciphertext = await _noise.encrypt(plain);
    return Frame(type: FrameType.transport, payload: ciphertext);
  }

  /// Decrypts an inbound transport frame and returns the plaintext message.
  Future<String> decryptText(Frame frame) async {
    if (frame.type != FrameType.transport) {
      throw ArgumentError('non-transport frame in decryptText: ${frame.type}');
    }
    if (!isEstablished) {
      throw StateError('decrypt called before handshake completed');
    }
    final plain = await _noise.decrypt(frame.payload);
    return utf8.decode(plain);
  }

  /// Marks the session as failed without zeroing the keys — used by the
  /// handshake watchdog so the UI can show a "retry" affordance instead
  /// of just blanking the conversation header.
  void markFailed() {
    _status = ChatSessionStatus.failed;
  }

  void destroy() {
    _noise.destroy();
    _status = ChatSessionStatus.failed;
  }
}
