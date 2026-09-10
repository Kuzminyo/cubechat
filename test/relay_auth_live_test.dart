// Opt-in read-only probe. It creates an ephemeral key, never loads an app
// identity, and never publishes a message or requests another recipient's mail.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_relay_protocol.dart';
import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final url in [
    'wss://relay.cubechat.tech',
    'wss://relay.cubechat.tech/geo',
  ]) {
    test(
      'authenticated empty inbox at $url',
      () async {
        final random = Random.secure();
        final signer = await Secp256k1NostrSigner.deriveFromSeed(
          Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
        );
        final ws =
            await WebSocket.connect(url).timeout(const Duration(seconds: 10));
        addTearDown(ws.close);
        final done = Completer<void>();
        var authenticated = false;
        String? authId;
        final sub = ws.listen(
          (raw) async {
            try {
              final msg = NostrRelayProtocol.parse(raw as String);
              switch (msg) {
                case RelayAuth(:final challenge):
                  final event = await signer.sign(
                    NostrEvent(
                      pubkey: signer.npubHex,
                      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                      kind: 22242,
                      tags: [
                        ['relay', url],
                        ['challenge', challenge],
                      ],
                      content: '',
                    ),
                  );
                  authId = event.id;
                  ws.add(jsonEncode(['AUTH', event.toJson()]));
                case RelayOk(:final eventId, :final accepted, :final message):
                  if (eventId != authId) break;
                  expect(accepted, isTrue, reason: message);
                  authenticated = true;
                  ws.add(
                    NostrRelayProtocol.req(
                      'probe',
                      recipientPubkeyHex: signer.npubHex,
                    ),
                  );
                case RelayEose():
                  expect(authenticated, isTrue);
                  if (!done.isCompleted) done.complete();
                case RelayClosed(:final message):
                  if (authenticated) throw StateError(message);
                default:
                  break;
              }
            } catch (e, stack) {
              if (!done.isCompleted) done.completeError(e, stack);
            }
          },
          onError: (Object e, StackTrace stack) {
            if (!done.isCompleted) done.completeError(e, stack);
          },
        );
        addTearDown(sub.cancel);
        ws.add(
          NostrRelayProtocol.req('probe', recipientPubkeyHex: signer.npubHex),
        );
        await done.future.timeout(const Duration(seconds: 15));
      },
      skip: !const bool.fromEnvironment('CUBECHAT_RELAY_PROBE'),
    );
  }
}
