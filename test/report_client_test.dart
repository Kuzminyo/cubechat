import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/identity_keys.dart';
import 'package:cubechat/core/crypto/identity_service.dart';
import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/features/moderation/data/report_client.dart';
import 'package:cubechat/features/moderation/domain/report.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

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

/// Everything `parseReportPayload` in `push/src/index.js` would need to see
/// in order to accept this — the fields it destructures, in the types and
/// caps it checks them against. Kept here rather than run against the real
/// JS (there is no JS runtime in a Dart test) so the payload shape is pinned
/// byte for byte the moment either side changes.
void _expectServerAcceptable(Map<String, Object?> json) {
  const reasons = {'spam', 'abuse', 'violence', 'sexual', 'other'};
  const contexts = {'direct', 'channel', 'airdrop', 'general'};
  const kinds = {'text', 'photo', 'video', 'voice', 'file', 'sticker', 'other'};
  final hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);
  final hex16 = RegExp(r'^[0-9a-f]{16}$', caseSensitive: false);

  expect(reasons.contains(json['reason']), isTrue);
  expect(contexts.contains(json['context']), isTrue);
  if (json.containsKey('note')) {
    final note = json['note'];
    expect(note, isA<String>());
    expect((note! as String).length, lessThanOrEqualTo(500));
  }
  if (json.containsKey('target')) {
    expect(json['target'], isA<String>());
    final target = json['target']! as String;
    expect(
        json['context'] == 'channel'
            ? hex16.hasMatch(target)
            : hex64.hasMatch(target),
        isTrue);
  }
  if (json.containsKey('targetNpub')) {
    expect(json['targetNpub'], isA<String>());
    expect(hex64.hasMatch(json['targetNpub']! as String), isTrue);
  }
  if (json.containsKey('channelId')) {
    expect(json['channelId'], isA<String>());
  }
  if (json.containsKey('message')) {
    final message = json['message']! as Map<String, Object?>;
    if (message.containsKey('text')) {
      final text = message['text'];
      expect(text, isA<String>());
      expect((text! as String).length, lessThanOrEqualTo(4000));
    }
    if (message.containsKey('kind')) {
      expect(kinds.contains(message['kind']), isTrue);
    }
    if (message.containsKey('sentAt')) {
      final sentAt = message['sentAt'];
      expect(sentAt, isA<int>());
      expect(sentAt! as int, greaterThanOrEqualTo(0));
    }
  }
  // Exactly the keys `parseReportPayload` destructures — an extra key would
  // still be accepted server-side (it's ignored), but a typo'd key name here
  // would silently drop a field the server was supposed to see, so the set
  // is pinned closed rather than just checked as a subset.
  expect(
    json.keys.toSet().difference(
      {
        'reason',
        'context',
        'note',
        'target',
        'targetNpub',
        'channelId',
        'message'
      },
    ),
    isEmpty,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModerationReport.toJson', () {
    test('a minimal general report', () {
      final report = ModerationReport(
        reason: ReportReason.spam,
        context: ReportContext.general,
      );
      final json = report.toJson();
      expect(json, {'reason': 'spam', 'context': 'general'});
      _expectServerAcceptable(json);
    });

    test('every field at once, and the message sub-object', () {
      final report = ModerationReport(
        reason: ReportReason.abuse,
        note: 'they kept messaging after I asked them to stop',
        target: 'a' * 64,
        targetNpub: 'b' * 64,
        context: ReportContext.direct,
        channelId: '#general',
        messageText: 'hello',
        messageKind: ReportedKind.text,
        messageSentAt: 1700000000,
      );
      final json = report.toJson();
      expect(json, {
        'reason': 'abuse',
        'context': 'direct',
        'note': 'they kept messaging after I asked them to stop',
        'target': 'a' * 64,
        'targetNpub': 'b' * 64,
        'channelId': '#general',
        'message': {
          'text': 'hello',
          'kind': 'text',
          'sentAt': 1700000000,
        },
      });
      _expectServerAcceptable(json);
    });

    test('note over 500 chars is truncated, never thrown', () {
      final report = ModerationReport(
        reason: ReportReason.other,
        note: 'x' * 600,
        context: ReportContext.general,
      );
      final json = report.toJson();
      expect((json['note']! as String).length, 500);
      _expectServerAcceptable(json);
    });

    test('message text over 4000 chars is truncated, never thrown', () {
      final report = ModerationReport(
        reason: ReportReason.other,
        context: ReportContext.channel,
        messageText: 'y' * 5000,
      );
      final json = report.toJson();
      final message = json['message']! as Map<String, Object?>;
      expect((message['text']! as String).length, 4000);
      _expectServerAcceptable(json);
    });

    test('fromJson is the inverse of toJson', () {
      final report = ModerationReport(
        reason: ReportReason.violence,
        note: 'note',
        target: 'c' * 64,
        context: ReportContext.airdrop,
        messageKind: ReportedKind.photo,
      );
      final restored = ModerationReport.fromJson(report.toJson());
      expect(restored, isNotNull);
      expect(restored!.toJson(), report.toJson());
    });

    test('fromJson returns null for garbage rather than throwing', () {
      expect(ModerationReport.fromJson({'reason': 'not-a-reason'}), isNull);
      expect(ModerationReport.fromJson({}), isNull);
    });
  });

  group('ReportClient', () {
    late Directory tempDir;
    late ProviderContainer container;
    late IdentityKeys identity;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_report_');
      Hive.init(tempDir.path);
      identity = await _identity();
      container = ProviderContainer(
        overrides: [identityProvider.overrideWith((_) async => identity)],
      );
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can briefly retain a Hive file handle after close.
      }
    });

    ReportClient makeClient({
      List<String>? endpoints,
      ReportPoster? post,
      DateTime Function()? now,
    }) {
      final provider = Provider<ReportClient>(
        (ref) => ReportClient(
          ref: ref,
          endpoints: endpoints,
          post: post,
          now: now,
        ),
      );
      return container.read(provider);
    }

    Future<List<Map<String, Object?>>> queueOnDisk() async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = box.get(ReportClient.storageKey);
      if (raw is! List) return <Map<String, Object?>>[];
      return <Map<String, Object?>>[
        for (final entry in raw)
          if (entry is Map) Map<String, Object?>.from(entry),
      ];
    }

    final report = ModerationReport(
      reason: ReportReason.spam,
      context: ReportContext.general,
    );

    test('send persists the report before it ever posts', () async {
      final postStarted = Completer<void>();
      final releasePost = Completer<int>();
      final client = makeClient(
        post: (uri, body) {
          postStarted.complete();
          return releasePost.future;
        },
      );

      final sendFuture = client.send(report);
      await postStarted.future;

      // The POST is deliberately still in flight here.
      final queued = await queueOnDisk();
      expect(queued, hasLength(1));

      releasePost.complete(200);
      expect(await sendFuture, isTrue);
      expect(await queueOnDisk(), isEmpty);
    });

    test('a completed send cannot erase a second report still queued',
        () async {
      final firstStarted = Completer<void>();
      final finishFirst = Completer<int>();
      var calls = 0;
      final client = makeClient(
        endpoints: const ['https://one.example/report'],
        post: (uri, body) {
          calls++;
          if (calls == 1) {
            firstStarted.complete();
            return finishFirst.future;
          }
          return Future<int>.value(-1);
        },
      );
      final first = client.send(report);
      await firstStarted.future;
      final second = client.send(
        ModerationReport(
            reason: ReportReason.abuse, context: ReportContext.general),
      );
      expect(await second, isFalse);
      finishFirst.complete(200);
      expect(await first, isTrue);
      final remaining = await queueOnDisk();
      expect(remaining, hasLength(1));
      expect((remaining.single['payload']! as Map)['reason'], 'abuse');
    });

    test('a 200 dequeues the report and returns true', () async {
      final client = makeClient(post: (uri, body) async => 200);
      expect(await client.send(report), isTrue);
      expect(await queueOnDisk(), isEmpty);
    });

    test('a network error (-1) keeps the report queued and returns false',
        () async {
      final client = makeClient(post: (uri, body) async => -1);
      expect(await client.send(report), isFalse);
      expect(await queueOnDisk(), hasLength(1));
    });

    test('a 5xx keeps the report queued and returns false', () async {
      final client = makeClient(post: (uri, body) async => 503);
      expect(await client.send(report), isFalse);
      expect(await queueOnDisk(), hasLength(1));
    });

    test('a 429 keeps the report queued and returns false, same as a 5xx',
        () async {
      final client = makeClient(post: (uri, body) async => 429);
      expect(await client.send(report), isFalse);
      expect(await queueOnDisk(), hasLength(1));
    });

    test('a 400 drops the report and reports permanent rejection', () async {
      final client = makeClient(post: (uri, body) async => 400);
      await expectLater(
          client.send(report), throwsA(isA<ReportRejectedException>()));
      expect(await queueOnDisk(), isEmpty);
    });

    test('a 401 drops the report and reports permanent rejection', () async {
      final client = makeClient(post: (uri, body) async => 401);
      await expectLater(
          client.send(report), throwsA(isA<ReportRejectedException>()));
      expect(await queueOnDisk(), isEmpty);
    });

    test('the second endpoint is tried when the first throws', () async {
      final tried = <Uri>[];
      final client = makeClient(
        endpoints: const [
          'https://one.example/report',
          'https://two.example/report'
        ],
        post: (uri, body) async {
          tried.add(uri);
          if (uri.host == 'one.example') throw const SocketException('down');
          return 200;
        },
      );
      expect(await client.send(report), isTrue);
      expect(tried.map((u) => u.host), ['one.example', 'two.example']);
      expect(await queueOnDisk(), isEmpty);
    });

    test(
        'the signed event carries kind 24242, the report tag, and the '
        'payload as its content', () async {
      NostrEvent? sent;
      final client = makeClient(
        post: (uri, body) async {
          sent = NostrEvent.fromJson(
            jsonDecode(body) as Map<String, dynamic>,
          );
          return 200;
        },
      );
      await client.send(report);

      expect(sent, isNotNull);
      expect(sent!.kind, 24242);
      expect(sent!.tags, [
        ['action', 'report'],
      ]);
      expect(
        jsonDecode(sent!.content) as Map<String, dynamic>,
        report.toJson(),
      );
      expect(sent!.pubkey, isNotEmpty);
      expect(sent!.sig, isNotNull);
    });

    test('flush() retries every queued report and keeps only the failures',
        () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final now = DateTime.now();
      await box.put(ReportClient.storageKey, [
        {
          'queuedAt': now.millisecondsSinceEpoch,
          'payload': ModerationReport(
            reason: ReportReason.spam,
            context: ReportContext.general,
          ).toJson(),
        },
        {
          'queuedAt': now.millisecondsSinceEpoch,
          'payload': ModerationReport(
            reason: ReportReason.abuse,
            context: ReportContext.general,
          ).toJson(),
        },
      ]);

      final posted = <String>[];
      final client = makeClient(
        post: (uri, body) async {
          final content =
              jsonDecode((jsonDecode(body) as Map)['content'] as String)
                  as Map<String, dynamic>;
          final reason = content['reason'] as String;
          posted.add(reason);
          return reason == 'spam' ? 200 : 503;
        },
        now: () => now,
      );

      await client.flush();

      expect(posted, containsAll(['spam', 'abuse']));
      final remaining = await queueOnDisk();
      expect(remaining, hasLength(1));
      final remainingPayload = remaining.first['payload']! as Map;
      expect(remainingPayload['reason'], 'abuse');
    });

    test(
        'flush() drops a report queued more than 7 days ago without '
        'ever posting it', () async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final now = DateTime.now();
      final stale = now.subtract(const Duration(days: 8));
      await box.put(ReportClient.storageKey, [
        {
          'queuedAt': stale.millisecondsSinceEpoch,
          'payload': report.toJson(),
        },
      ]);

      var postCalls = 0;
      final client = makeClient(
        post: (uri, body) async {
          postCalls++;
          return 200;
        },
        now: () => now,
      );

      await client.flush();

      expect(postCalls, 0);
      expect(await queueOnDisk(), isEmpty);
    });

    test('flush() on an empty queue does nothing', () async {
      var postCalls = 0;
      final client = makeClient(
        post: (uri, body) async {
          postCalls++;
          return 200;
        },
      );
      await client.flush();
      expect(postCalls, 0);
    });
  });
}
