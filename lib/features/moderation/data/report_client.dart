import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/crypto/identity_service.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/nostr/nostr_event.dart';
import '../../../core/transport/nostr/nostr_signer.dart';
import '../../../core/util/debug_log.dart';
import '../domain/report.dart';

/// One attempt at one endpoint: `POST` [body] to [endpoint], and hand back the
/// HTTP status code — or `-1` for anything that never produced one (DNS
/// failure, connection refused, a timeout). The same "never throws" contract
/// `PushRegistration._post` uses, so [ReportClient] never has to tell a
/// deliberate 4xx/5xx apart from a network exception with a try/catch of its
/// own — it just reads the int. Injectable so tests can script every outcome
/// `handleReport` can produce without a real socket.
typedef ReportPoster = Future<int> Function(Uri endpoint, String body);

Future<int> _defaultPost(Uri endpoint, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 20));
    await response.drain<void>();
    return response.statusCode;
  } catch (e) {
    DebugLog.instance.log('REPORT', '${endpoint.host} did not answer: $e');
    return -1;
  } finally {
    client.close(force: true);
  }
}

/// What happened when [ReportClient] tried to send one queued report.
class ReportRejectedException implements Exception {
  const ReportRejectedException();
}

enum _Outcome {
  /// 200 — accepted, drop it from the queue.
  accepted,

  /// 400 or 401 — the server will never accept this exact payload (bad shape,
  /// bad signature, a stale clock). Retrying would just repeat the refusal
  /// forever, so it is dropped and logged rather than kept.
  drop,

  /// Everything else: no endpoint answered, or one answered 429 or 5xx.
  /// Stays queued for the next `flush()`.
  retry,
}

/// Signs a report with the phone's own Nostr identity, POSTs it, and keeps a
/// durable queue so a report survives being offline, a dead server, or the
/// app being killed mid-send.
///
/// Signing copies `TurnCredentialsClient`'s `/turn` request exactly — same
/// kind (24242), same derivation
/// (`Secp256k1NostrSigner.deriveFromSeed(identity.signPrivateKey)`) — with its
/// own purpose tag (`['action', 'report']`) so a report can never be replayed
/// as a TURN request or vice versa (see the comment on `REPORT_KIND` in
/// `push/src/index.js`).
///
/// The queue is re-signed on every attempt rather than signed once and
/// replayed, because the server's freshness window is only 600s past / 60s
/// future (`REPORT_MAX_PAST_SECONDS`/`REPORT_MAX_FUTURE_SECONDS`) — a report
/// that sat offline for an hour would otherwise come back 401 `stale` forever.
class ReportClient {
  ReportClient({
    required Ref ref,
    List<String>? endpoints,
    ReportPoster? post,
    DateTime Function()? now,
  })  : _ref = ref,
        _endpoints = endpoints ?? defaultEndpoints,
        _post = post ?? _defaultPost,
        _now = now ?? DateTime.now;

  final Ref _ref;
  final List<String> _endpoints;
  final ReportPoster _post;
  final DateTime Function() _now;

  static const String storageKey = 'moderation.reportQueue';

  /// Same shape of fallback as `PushRegistration.endpoints`: the real name
  /// first, the sslip.io stand-in behind it, tried in order until one
  /// answers.
  static const List<String> defaultEndpoints = <String>[
    'https://push.cubechat.tech/report',
    'https://209-38-225-225.sslip.io/report',
  ];

  /// A queued report older than this is a report about a moment nobody can
  /// still act on — dropped on `flush()` rather than sent forever.
  static const Duration maxQueueAge = Duration(days: 7);

  static const int _reportKind = 24242;

  Box<dynamic>? _box;
  Future<Box<dynamic>>? _opening;
  Future<void> _queueTail = Future<void>.value();
  final Set<String> _inFlight = <String>{};
  int _nextEntry = 0;

  String _newId() => '${_now().microsecondsSinceEpoch}-${_nextEntry++}';

  Future<T> _withQueue<T>(Future<T> Function(Box<dynamic>) action) {
    final result = _queueTail.then((_) async => action(await _openBox()));
    _queueTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _remove(String id) => _withQueue((box) async {
        final queue = _readQueue(box)
          ..removeWhere((entry) => entry['id'] == id);
        await _writeQueue(box, queue);
      });

  Future<Box<dynamic>> _openBox() {
    final box = _box;
    if (box != null) return Future<Box<dynamic>>.value(box);
    return _opening ??=
        hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings).then(
      (box) {
        _box = box;
        return box;
      },
    );
  }

  List<Map<String, Object?>> _readQueue(Box<dynamic> box) {
    final raw = box.get(storageKey);
    if (raw is! List) return <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final entry in raw)
        if (entry is Map) Map<String, Object?>.from(entry),
    ];
  }

  Future<void> _writeQueue(
    Box<dynamic> box,
    List<Map<String, Object?>> queue,
  ) =>
      box.put(storageKey, queue);

  /// Queue [report] first (persisted — a crash right after this call still
  /// has it on disk), then try once to send it. Returns whether the server
  /// accepted it *now*; `false` means it remains queued. A permanent server
  /// refusal throws after removing the entry, so the UI cannot say it will retry.
  Future<bool> send(ModerationReport report) async {
    final id = _newId();
    final entry = <String, Object?>{
      'id': id,
      'queuedAt': _now().millisecondsSinceEpoch,
      'payload': report.toJson(),
    };
    _inFlight.add(id);
    try {
      await _withQueue((box) async {
        final queue = _readQueue(box)..add(entry);
        await _writeQueue(box, queue);
      });
      final outcome = await _attempt(entry);
      if (outcome == _Outcome.retry) return false;
      await _remove(id);
      if (outcome == _Outcome.drop) throw const ReportRejectedException();
      return true;
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Retry a durable snapshot. Each completion removes only its own entry:
  /// a simultaneous send must never be overwritten by an older flush result.
  Future<void> flush() async {
    final snapshot = await _withQueue((box) async {
      final queue = _readQueue(box);
      var upgraded = false;
      for (final entry in queue) {
        if (entry['id'] is! String) {
          entry['id'] = _newId();
          upgraded = true;
        }
      }
      if (upgraded) await _writeQueue(box, queue);
      return queue;
    });
    if (snapshot.isEmpty) return;

    final cutoff = _now().subtract(maxQueueAge).millisecondsSinceEpoch;
    for (final entry in snapshot) {
      final id = entry['id']! as String;
      if (_inFlight.contains(id)) continue;
      _inFlight.add(id);
      try {
        final queuedAt = entry['queuedAt'];
        if (queuedAt is int && queuedAt < cutoff) {
          DebugLog.instance.log(
            'REPORT',
            'dropping a report queued more than ${maxQueueAge.inDays} days ago',
          );
          await _remove(id);
          continue;
        }
        final outcome = await _attempt(entry);
        if (outcome != _Outcome.retry) await _remove(id);
      } finally {
        _inFlight.remove(id);
      }
    }
  }

  /// Emergency wipe: forget every report still waiting to be sent. A queued
  /// report names the person reported and quotes what they wrote, which is
  /// exactly the kind of trace a wipe promises to leave nowhere. Chained on
  /// the queue like every other write, so a send finishing mid-wipe cannot
  /// write the list back afterwards.
  Future<void> clear() => _withQueue((box) => box.delete(storageKey));

  /// Sign [entry]'s payload fresh and try each endpoint in turn until one
  /// gives a definite answer (200, 400 or 401). A network failure or a
  /// 429/5xx moves on to the next endpoint rather than stopping — the same
  /// shape `PushRegistration._publish` uses — and if none of them answer
  /// definitely, the report stays queued for the next `flush()` (a 429 gets
  /// no different treatment than a 5xx: both mean "not now", and the next
  /// `flush()` — at the next launch or the next time connectivity returns,
  /// never a tight loop — is the backoff).
  Future<_Outcome> _attempt(Map<String, Object?> entry) async {
    final payload = entry['payload'];
    if (payload is! Map) return _Outcome.drop;
    final report = ModerationReport.fromJson(payload);
    if (report == null) return _Outcome.drop;

    final NostrEvent event;
    try {
      final identity = await _ref.read(identityProvider.future);
      final signer = await Secp256k1NostrSigner.deriveFromSeed(
        Uint8List.fromList(identity.signPrivateKey),
      );
      event = await signer.sign(
        NostrEvent(
          pubkey: signer.npubHex,
          createdAt: _now().millisecondsSinceEpoch ~/ 1000,
          kind: _reportKind,
          tags: const <List<String>>[
            <String>['action', 'report'],
          ],
          content: jsonEncode(report.toJson()),
        ),
      );
    } catch (e) {
      DebugLog.instance.log('REPORT', 'could not sign the report: $e');
      return _Outcome.retry;
    }

    final body = jsonEncode(event.toJson());
    for (final endpoint in _endpoints) {
      final uri = Uri.parse(endpoint);
      int status;
      try {
        // The default poster already turns a network failure into `-1`
        // rather than throwing, but an injected test poster is not bound to
        // that contract — a thrown exception here is still just "this
        // endpoint didn't answer", so it is treated the same way.
        status = await _post(uri, body);
      } catch (e) {
        DebugLog.instance.log('REPORT', '${uri.host} did not answer: $e');
        continue;
      }
      if (status == 200) return _Outcome.accepted;
      if (status == 400 || status == 401) {
        DebugLog.instance.log(
          'REPORT',
          'server refused the report (status $status) — dropping it',
        );
        return _Outcome.drop;
      }
      // -1 (network failure), 429 (rate limit) or 5xx: try the next endpoint.
    }
    return _Outcome.retry;
  }
}

final reportClientProvider = Provider<ReportClient>((ref) {
  return ReportClient(ref: ref);
});
