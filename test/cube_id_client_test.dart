import 'dart:convert';

import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/features/cube_id/data/cube_id_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CubeIdClient client(int status, String response) => CubeIdClient(
        http: (method, uri, {body}) async => (status: status, body: response),
      );

  test('card decodes base64url and 404 or no answer is null', () async {
    final bytes = List<int>.generate(10, (i) => i);
    final ok = CubeIdClient(
      http: (m, u, {body}) async => (
        status: 200,
        body: jsonEncode({'card': base64Url.encode(bytes).replaceAll('=', '')}),
      ),
    );
    expect(await ok.card('@Dima'), bytes);
    expect(await client(404, '{"error":"not-found"}').card('x'), isNull);
    expect(await client(-1, '').card('x'), isNull);
  });

  test('send maps statuses to results', () async {
    final e = NostrEvent(
      pubkey: 'a',
      createdAt: 0,
      kind: 24243,
      tags: const [],
      content: '{}',
    );
    expect(await client(200, '{"name":"dima"}').send(e), isA<CubeIdOk>());
    final refused = await client(409, '{"error":"taken"}').send(e);
    expect((refused as CubeIdRefused).code, 'taken');
    expect(await client(-1, '').send(e), isA<CubeIdOffline>());
    expect(await client(503, '').send(e), isA<CubeIdOffline>());
  });

  test('available normalises the name in the URL', () async {
    Uri? seen;
    final c = CubeIdClient(
      http: (m, u, {body}) async {
        seen = u;
        return (status: 200, body: '{"available":true}');
      },
    );
    expect((await c.available('@Dima'))!.available, isTrue);
    expect(seen!.path, '/v1/available/dima');
  });
}
