import 'dart:async';

import 'package:cubechat/core/transport/nostr/websocket_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _ControlledChannel implements WebSocketChannel {
  _ControlledChannel() {
    incoming.onCancel = () => cancelled = true;
  }
  final incoming = StreamController<dynamic>();
  final handshake = Completer<void>();
  bool cancelled = false;
  @override
  final _ControlledSink sink = _ControlledSink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready => handshake.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledSink implements WebSocketSink {
  bool closed = false;
  @override
  Future<void> close([int? code, String? reason]) async => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  for (final rejectLate in [false, true]) {
    test('late ready ${rejectLate ? "failure" : "success"} cannot affect replacement', () async {
      final old = _ControlledChannel();
      final replacement = _ControlledChannel();
      var attempts = 0;
      const url = 'ws://localhost:12345';
      final client = WebSocketNostrRelayClient(
        relayUrls: [url],
        connect: (_) => attempts++ == 0 ? old : replacement,
      );
      addTearDown(client.dispose);
      client.start();
      old.incoming.addError(StateError('stream failed before ready'));
      await _turn();
      expect(client.states[url], RelayState.failed);
      expect(old.cancelled, isTrue);
      expect(old.sink.closed, isTrue);
      client.wake();
      expect(attempts, 2);
      expect(client.states[url], RelayState.connecting);
      if (rejectLate) {
        old.handshake.completeError(StateError('late handshake failure'));
      } else {
        old.handshake.complete();
      }
      await _turn();
      expect(client.states[url], RelayState.connecting);
      expect(replacement.cancelled, isFalse);
      expect(replacement.sink.closed, isFalse);
      replacement.handshake.complete();
      await _turn();
      expect(client.isConnected, isTrue);
      await client.dispose();
      expect(replacement.cancelled, isTrue);
      expect(replacement.sink.closed, isTrue);
    });
  }
}
