import 'dart:convert';
import 'dart:io';

import 'package:cubechat/features/call/data/turn_credentials_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('access is cached, shared and refreshed before expiry', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    var clock = DateTime.utc(2026, 9, 13);
    server.listen((request) async {
      requests++;
      expect(
          jsonDecode(await utf8.decoder.bind(request).join()), {'proof': true});
      request.response.write(jsonEncode({
        'ok': true,
        'username': 'user',
        'password': 'pass',
        'ttl': 600,
        'urls': ['turn:example.com:3478']
      }));
      await request.response.close();
    });
    final client = TurnCredentialsClient(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/turn'),
      signRequest: () async => {'proof': true},
      now: () => clock,
    );
    try {
      final access = await Future.wait([client.obtain(), client.obtain()]);
      expect(requests, 1);
      expect(access.first.expiresAt, clock.add(const Duration(seconds: 600)));
      expect(
          (await client.obtain())
              .configuration(allowDirect: false)['iceTransportPolicy'],
          'relay');
      expect(requests, 1);
      clock = clock.add(const Duration(seconds: 541));
      await client.obtain();
      expect(requests, 2);
    } finally {
      await server.close(force: true);
    }
  });

  test('a refused or incomplete response never becomes a direct call',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final responses = [
      (401, <String, Object>{'ok': false, 'reason': 'signature'}),
      (503, <String, Object>{'ok': false, 'reason': 'unconfigured'}),
      (
        200,
        <String, Object>{
          'ok': true,
          'username': 'u',
          'password': 'p',
          'ttl': 600,
          'urls': <String>[]
        }
      ),
    ];
    var index = 0;
    server.listen((request) async {
      await request.drain<void>();
      final response = responses[index++];
      request.response.statusCode = response.$1;
      request.response.write(jsonEncode(response.$2));
      await request.response.close();
    });
    final client = TurnCredentialsClient(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/turn'),
      signRequest: () async => {},
    );
    try {
      for (var i = 0; i < responses.length; i++) {
        await expectLater(client.obtain(), throwsA(isA<TurnUnavailable>()));
      }
    } finally {
      await server.close(force: true);
    }
  });
}
