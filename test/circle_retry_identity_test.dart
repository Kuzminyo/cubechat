import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:cubechat/core/ble/ble_peripheral.dart';
import 'package:cubechat/core/crypto/identity_keys.dart';
import 'package:cubechat/core/crypto/identity_service.dart';
import 'package:cubechat/core/crypto/sealed_box.dart';
import 'package:cubechat/core/crypto/signed_payload.dart';
import 'package:cubechat/core/transport/envelope.dart';
import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/transport/peer_id.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/data/peripheral_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/hive_settle.dart';

class _Peripheral implements BlePeripheral {
  final incoming = StreamController<PeripheralEvent>.broadcast();
  @override
  Stream<PeripheralEvent> events() => incoming.stream;
  @override
  Future<void> stop() async {}
  @override
  Future<bool> notifyInbound(Uint8List bytes) async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Offline extends RelaySettingsController {
  @override
  RelaySettings build() => const RelaySettings(enabled: false, urls: []);
}

class _Roster extends KnownPeersController {
  _Roster(this.peer);
  final KnownPeer peer;
  @override
  Map<String, KnownPeer> build() => {peer.pubkeyHex: peer};
}

Future<IdentityKeys> _identity() async {
  final x = await X25519().newKeyPair();
  final ed = await Ed25519().newKeyPair();
  return IdentityKeys(
    publicKey: Uint8List.fromList((await x.extractPublicKey()).bytes),
    privateKey: Uint8List.fromList(await x.extractPrivateKeyBytes()),
    signPublicKey: Uint8List.fromList((await ed.extractPublicKey()).bytes),
    signPrivateKey: Uint8List.fromList(await ed.extractPrivateKeyBytes()),
  );
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a relayed circle keeps its author as the retry destination', () async {
    final dir = await Directory.systemTemp.createTemp('cubechat_circle_retry_');
    Hive.init(dir.path);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final receiver = await _identity();
    final sender = await _identity();
    final senderId = _hex(sender.publicKey);
    final peripheral = _Peripheral();
    final container = ProviderContainer(overrides: [
      blePeripheralProvider.overrideWithValue(peripheral),
      identityProvider.overrideWith((_) async => receiver),
      relaySettingsProvider.overrideWith(_Offline.new),
      knownPeersControllerProvider.overrideWith(() => _Roster(KnownPeer(
            pubkeyHex: senderId,
            displayName: 'Sender',
            lastSeen: DateTime.now(),
            signPublicKey: sender.signPublicKey,
          ))),
    ]);
    try {
      container.read(messagingServiceProvider);
      await container.read(fileTransferControllerProvider.notifier).loaded;
      final mediaId = Uint8List.fromList(List.filled(16, 7));
      final origin = await PeerId.legacy(sender.publicKey);
      final dest = await PeerId.legacy(receiver.publicKey);
      final msgId = Uint8List.fromList(List.filled(16, 8));
      final manifest = MediaManifest(
        mediaId: mediaId,
        kind: MediaKind.file,
        total: 2,
        mime: 'video/mp4',
        name: 'circle.mp4',
        sha256: Uint8List(32),
      );
      final signed = await SignedPayload.wrap(
        inner:
            packInnerPayload(InnerPayloadType.mediaManifest, manifest.encode()),
        context: SignedPayload.contextBytes(
            originPubkeyHash: origin, destPubkeyHash: dest, msgId: msgId),
        signKeyPair: sender.asSignKeyPair(),
        senderEdPub: sender.signPublicKey,
      );
      final sealed = await SealedBox.seal(signed, receiver.publicKey);
      final bytes = Frame(
              type: FrameType.transport,
              payload: TransportEnvelope(
                originPubkeyHash: origin,
                destPubkeyHash: dest,
                msgId: msgId,
                ttl: 0,
                body: Uint8List.fromList([1, ...sealed]),
              ).encode())
          .encode();
      final arrived = Completer<void>();
      final subscription =
          container.listen(fileTransferControllerProvider, (_, next) {
        if (next.containsKey(_hex(mediaId)) && !arrived.isCompleted)
          arrived.complete();
      });
      try {
        // Feed the public inbound transport boundary; no Noise session for
        // this hop. The signature, not its address, identifies the author.
        peripheral.incoming.add(PeripheralWrite(
          centralId: 'nostr:relay',
          charUuid: BleConstants.outboundCharUuid,
          data: bytes,
        ));
        await arrived.future.timeout(const Duration(seconds: 5));
        final task =
            container.read(fileTransferControllerProvider)[_hex(mediaId)]!;
        expect(task.chatId, senderId);
        expect(task.completedUnits, 0);
        expect(task.totalUnits, 2);
        expect(
          await container
              .read(messagingServiceProvider)
              .requestMediaAgain(senderId, _hex(mediaId)),
          isFalse,
          reason:
              'an offline request must not consume the stalled-transfer retry budget',
        );
      } finally {
        subscription.close();
      }
    } finally {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await settleBackgroundStorage();
      await peripheral.incoming.close();
      await Hive.close();
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {/* Windows lock. */}
    }
  });
}
