import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:cubechat/features/pro/data/wallet_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  // Signing needs the identity, which is minted through secure storage.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<({Uri url, Map<String, Object?> json})> sent;
  late Secp256k1NostrSigner signer;

  /// The api with a transport that records what was asked and answers with
  /// whatever the test wants.
  WalletApi apiThat({
    required int status,
    Map<String, Object?> body = const <String, Object?>{},
    bool throws = false,
  }) {
    return HttpWalletApi(
      signer: () async => signer,
      transport: (url, json) async {
        sent.add((url: url, json: json));
        if (throws) throw const SocketException('no route');
        return (status: status, body: body);
      },
    );
  }

  setUp(() async {
    sent = [];
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('cubechat_wallet_');
    Hive.init(tempDir.path);
    signer = await Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(List<int>.filled(32, 7)),
    );
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('a balance request is signed and asks the balance endpoint', () async {
    final api = apiThat(status: 200, body: {'cubes': 42});

    final reply = await api.balance();

    expect(reply, isA<WalletOk>());
    expect((reply as WalletOk).cubes, 42);
    expect(sent.single.url.path, '/balance');
    final event = sent.single.json['event']! as Map<String, Object?>;
    expect(event['sig'], isNotNull);
    expect(event['kind'], HttpWalletApi.walletKind);
  });

  test('a credit never names an amount', () async {
    // The server decides what a product is worth. A client that could say so
    // is a client that credits itself.
    final api = apiThat(status: 200, body: {'cubes': 300});

    await api.credit(platform: 'apple', token: 'tk', productId: 'cubes.300');

    final event = sent.single.json['event']! as Map<String, Object?>;
    final tags = (event['tags']! as List).cast<List<Object?>>();
    final names = tags.map((t) => t.first).toList();
    expect(names, contains('product'));
    expect(names, isNot(contains('amount')));
    expect(names, isNot(contains('cubes')));
  });

  test('a transfer carries an id so a retry is the same payment', () async {
    final api = apiThat(status: 200, body: {'cubes': 6});

    await api.transfer(to: 'c' * 64, amount: 4, id: 't1');

    // Flattened to a map first: `contains` on a List of Lists compares by
    // identity, so two equal-looking tags are never equal to each other.
    final event = sent.single.json['event']! as Map<String, Object?>;
    final tags = <String, String>{
      for (final t in (event['tags']! as List).cast<List<Object?>>())
        '${t.first}': '${t[1]}',
    };
    expect(tags['id'], 't1');
    expect(tags['amount'], '4');
    expect(tags['to'], 'c' * 64);
  });

  test('a refusal keeps the reason the server gave', () async {
    final api = apiThat(status: 400, body: {'error': 'insufficient'});

    final reply = await api.transfer(to: 'c' * 64, amount: 9999, id: 't2');

    expect(reply, isA<WalletRefused>());
    expect((reply as WalletRefused).code, 'insufficient');
  });

  test('no network is told apart from a refusal', () async {
    // One of them is worth retrying and the other never is, so a caller that
    // cannot tell will either nag or give up wrongly.
    final api = apiThat(status: 200, throws: true);

    expect(await api.balance(), isA<WalletUnreachable>());
  });

  test('a 200 without a number is not read as a balance', () async {
    final api = apiThat(status: 200, body: {'cubes': 'lots'});

    expect(await api.balance(), isA<WalletRefused>());
  });
}
