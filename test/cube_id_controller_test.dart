import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/cube_id/data/cube_id_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:cubechat/features/cube_id/data/cube_id_controller.dart';
import 'package:cubechat/features/cube_id/data/known_names_controller.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/hive_settle.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final containers = <ProviderContainer>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    dir = await Directory.systemTemp.createTemp('cubechat_cube_id_');
    PathProviderPlatform.instance = _Paths(dir.path);
    Hive.init(dir.path);
    // Any fixed bytes do: these tests are about what the controller sends and
    // keeps, not about the card itself.
    CubeIdController.cardSourceOverride =
        (_) async => Uint8List.fromList(List<int>.generate(200, (i) => i));
  });

  tearDown(() async {
    CubeIdController.cardSourceOverride = null;
    await settleBackgroundStorage();
    for (final c in containers) {
      c.dispose();
    }
    containers.clear();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  ProviderContainer containerWith(CubeIdHttp http) {
    final c = ProviderContainer(
      overrides: [
        cubeIdClientProvider.overrideWithValue(CubeIdClient(http: http)),
      ],
    );
    containers.add(c);
    return c;
  }

  String opOf(String? body) =>
      (jsonDecode(jsonDecode(body!)['content'] as String) as Map)['op']
          as String;

  test('claim stores the name and sends a proof-of-work claim with our card',
      () async {
    final sent = <Map<String, dynamic>>[];
    final c = containerWith((m, u, {body}) async {
      if (body != null) sent.add(jsonDecode(body) as Map<String, dynamic>);
      return (status: 200, body: '{"name":"dima"}');
    });
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    expect(await ctl.claim('@Dima'), isA<CubeIdOk>());
    expect(c.read(cubeIdControllerProvider).name, 'dima');
    final content = jsonDecode(sent.single['content'] as String) as Map;
    expect(content['op'], 'claim');
    expect(content['name'], 'dima');
    expect((content['card'] as String).isNotEmpty, isTrue);
    expect((sent.single['tags'] as List).single.first, 'nonce');
  });

  test('a name that breaks the rules never reaches the network', () async {
    var calls = 0;
    final c = containerWith((m, u, {body}) async {
      calls++;
      return (status: 200, body: '{}');
    });
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    expect((await ctl.claim('ab') as CubeIdRefused).code, 'invalid');
    expect((await ctl.claim('admin') as CubeIdRefused).code, 'reserved');
    expect(calls, 0);
  });

  test('a refused claim keeps no name', () async {
    final c = containerWith(
      (m, u, {body}) async => (status: 409, body: '{"error":"taken"}'),
    );
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    expect((await ctl.claim('dima') as CubeIdRefused).code, 'taken');
    expect(c.read(cubeIdControllerProvider).name, isNull);
  });

  test('a second claim is a rename', () async {
    final ops = <String>[];
    final c = containerWith((m, u, {body}) async {
      if (body != null) ops.add(opOf(body));
      return (status: 200, body: '{}');
    });
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    await ctl.claim('dima');
    await ctl.claim('dmytro');
    expect(ops, ['claim', 'rename']);
    expect(c.read(cubeIdControllerProvider).name, 'dmytro');
  });

  test('maintain renews after 7 days and updates when our card changed',
      () async {
    final ops = <String>[];
    final c = containerWith((m, u, {body}) async {
      if (body != null) ops.add(opOf(body));
      return (status: 200, body: '{"name":"dima"}');
    });
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    await ctl.claim('dima');
    ops.clear();
    await ctl.maintain();
    expect(ops, isEmpty);
    ctl.debugSetRenewedAt(DateTime.now().subtract(const Duration(days: 8)));
    await ctl.maintain();
    expect(ops, ['renew']);
    ctl.debugSetCardDigest('stale');
    ops.clear();
    await ctl.maintain();
    expect(ops, ['update']);
  });

  test('a claim carries "nobody", and maintain re-sends a reach that never '
      'reached the server', () async {
    final sent = <Map<dynamic, dynamic>>[];
    var offline = false;
    final c = containerWith((m, u, {body}) async {
      if (offline) return (status: -1, body: '');
      if (body != null) {
        sent.add(jsonDecode(jsonDecode(body)['content'] as String) as Map);
      }
      return (status: 200, body: '{}');
    });
    final privacy = c.read(privacySettingsProvider.notifier);
    await privacy.loaded;
    await privacy.setStrangerReach(StrangerReach.none);
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    await ctl.claim('dima');
    expect(sent.single['reach'], 'none');

    // The switch goes back to "everyone" while the server is unreachable…
    offline = true;
    await privacy.setStrangerReach(StrangerReach.all);
    await Future<void>.delayed(Duration.zero);
    offline = false;
    sent.clear();
    // …so the next maintain sends it, card unchanged or not.
    await ctl.maintain();
    expect(sent.single['op'], 'update');
    expect(sent.single['reach'], 'all');
    sent.clear();
    await ctl.maintain();
    expect(sent, isEmpty);
  });

  test('a name the server no longer has is forgotten here too', () async {
    var claimed = false;
    final c = containerWith((m, u, {body}) async {
      if (!claimed) {
        claimed = true;
        return (status: 200, body: '{}');
      }
      return (status: 404, body: '{"error":"no-name"}');
    });
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    await ctl.claim('dima');
    ctl.debugSetRenewedAt(DateTime.now().subtract(const Duration(days: 8)));
    await ctl.maintain();
    expect(c.read(cubeIdControllerProvider).name, isNull);
  });

  test('the name survives a restart', () async {
    final first = containerWith(
      (m, u, {body}) async => (status: 200, body: '{}'),
    );
    final ctl = first.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    await ctl.claim('dima');
    final second = containerWith(
      (m, u, {body}) async => (status: 200, body: '{}'),
    );
    await second.read(cubeIdControllerProvider.notifier).loaded;
    expect(second.read(cubeIdControllerProvider).name, 'dima');
  });

  test('release clears the name and does not wait past the timeout', () async {
    var slow = false;
    final c = containerWith((m, u, {body}) async {
      if (slow) await Future<void>.delayed(const Duration(seconds: 10));
      return (status: 200, body: '{}');
    });
    final ctl = c.read(cubeIdControllerProvider.notifier);
    await ctl.loaded;
    await ctl.claim('dima');
    slow = true;
    final clock = Stopwatch()..start();
    await ctl.release(timeout: const Duration(milliseconds: 200));
    expect(clock.elapsedMilliseconds, lessThan(1500));
    expect(c.read(cubeIdControllerProvider).name, isNull);
  });

  test('lookup rejects a card with a broken signature', () async {
    final c = containerWith(
      (m, u, {body}) async => (
        status: 200,
        body: jsonEncode({'card': base64Url.encode(List<int>.filled(200, 1))}),
      ),
    );
    final ctl = c.read(cubeIdControllerProvider.notifier);
    expect(await ctl.lookupAndAdd('@dima'), isA<LookupNotFound>());
  });

  test('lookup refuses a real card whose signature was altered', () async {
    final sign = await Ed25519().newKeyPair();
    final card = await PeerAnnouncement(
      pubkey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
      signPubkey: Uint8List.fromList((await sign.extractPublicKey()).bytes),
      signedPrekeyPub: Uint8List(32),
      nostrPubkey: Uint8List.fromList(List<int>.filled(32, 9)),
      nickname: 'Dima',
    ).sign(await sign.extract());
    // The untouched card is one this build accepts, so the flip below is the
    // only reason the lookup can fail.
    await PeerAnnouncement.verifyAndDecode(card);
    final forged = Uint8List.fromList(card)..last ^= 0x01;
    final c = containerWith(
      (m, u, {body}) async => (
        status: 200,
        body: jsonEncode({'card': base64Url.encode(forged)}),
      ),
    );
    final ctl = c.read(cubeIdControllerProvider.notifier);
    expect(await ctl.lookupAndAdd('@dima'), isA<LookupNotFound>());
    await c.read(knownNamesProvider.notifier).loaded;
    expect(c.read(knownNamesProvider), isEmpty);
  });

  test('lookup says offline when nothing answers', () async {
    final c = containerWith((m, u, {body}) async => (status: -1, body: ''));
    final ctl = c.read(cubeIdControllerProvider.notifier);
    expect(await ctl.lookupAndAdd('dima'), isA<LookupOffline>());
  });
}
