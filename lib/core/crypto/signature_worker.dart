import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../util/debug_log.dart';
import 'secp256k1.dart';

/// Checks inbound relay signatures somewhere other than the thread that draws.
///
/// **The measurement this exists for.** A `[COST]` line from a phone receiving
/// a circle, 2026-09-09: `nostr-verify 54× 204 ms sync`. Just under four
/// milliseconds of *synchronous* Dart per event, on the UI isolate, and a file
/// is one event per chunk — a minute-long circle was six hundred of them.
/// BIP-340 is implemented in this repo in Dart (`secp256k1.dart`) because
/// shipping a native crypto dependency was not wanted, and a scalar
/// multiplication in Dart has no suspension point in it: nothing else on that
/// thread runs until it finishes. Frames included.
///
/// So it moves. One long-lived isolate, not a `compute` per event — spawning an
/// isolate costs more than the verify it would perform, and this runs hundreds
/// of times in a row. The messages are a few hundred bytes each except for the
/// event body, which is copied once; against a hash and a scalar multiply that
/// copy is not measurable.
///
/// **Safe to run off the main isolate** because none of it touches a platform
/// channel: `Cryptography.instance` is the pure-Dart implementation here — the
/// app never calls `FlutterCryptography.enable()` — so the SHA-256 inside the
/// tagged hashes is Dart as well.
///
/// Falls back to verifying in place if the isolate will not start. A phone that
/// cannot spawn one should still receive messages, slowly, rather than reject
/// every signature it is shown.
class SignatureWorker {
  SignatureWorker._();
  static final SignatureWorker instance = SignatureWorker._();

  SendPort? _requests;
  Future<void>? _starting;
  bool _broken = false;
  int _nextId = 0;
  final Map<int, Completer<bool>> _pending = {};

  /// Verify one relay event: that its id really hashes its fields, and that the
  /// Schnorr signature is its author's.
  ///
  /// Both checks together in one crossing, because doing them separately would
  /// pay the round trip twice for work that always happens as a pair.
  Future<bool> verifyEvent({
    required String serialized,
    required String idHex,
    required String pubkeyHex,
    required String sigHex,
  }) async {
    final request = _VerifyRequest(
      serialized: serialized,
      idHex: idHex,
      pubkeyHex: pubkeyHex,
      sigHex: sigHex,
    );
    if (_broken) return _verifyInPlace(request);
    try {
      await (_starting ??= _start());
    } catch (_) {
      return _verifyInPlace(request);
    }
    final port = _requests;
    if (port == null) return _verifyInPlace(request);

    final id = _nextId++;
    final completer = Completer<bool>();
    _pending[id] = completer;
    port.send((id, request.serialized, request.idHex, request.pubkeyHex,
        request.sigHex));
    return completer.future;
  }

  Future<void> _start() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    replies.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is (int, bool)) {
        _pending.remove(message.$1)?.complete(message.$2);
      }
    });
    try {
      await Isolate.spawn(
        _serve,
        replies.sendPort,
        debugName: 'cubechat-signatures',
      );
      _requests = await ready.future.timeout(const Duration(seconds: 5));
      DebugLog.instance.log('CRYPTO', 'signature isolate up');
    } catch (e) {
      // Whatever went wrong, the answer is to keep working rather than to stop
      // accepting mail. Said once, not once per event.
      replies.close();
      _broken = true;
      DebugLog.instance
          .log('CRYPTO', 'signature isolate unavailable ($e) — verifying '
              'on the main isolate, which will be slower');
      rethrow;
    }
  }

  static Future<bool> _verifyInPlace(_VerifyRequest r) => _check(r);

  /// The isolate's whole life: take requests, answer them, never exit.
  static void _serve(SendPort replies) {
    final requests = ReceivePort();
    replies.send(requests.sendPort);
    requests.listen((Object? message) async {
      if (message is! (int, String, String, String, String)) return;
      final (id, serialized, idHex, pubkeyHex, sigHex) = message;
      final ok = await _check(
        _VerifyRequest(
          serialized: serialized,
          idHex: idHex,
          pubkeyHex: pubkeyHex,
          sigHex: sigHex,
        ),
      );
      replies.send((id, ok));
    });
  }

  static final _sha256 = Sha256();

  static Future<bool> _check(_VerifyRequest r) async {
    try {
      // The id first: it is a hash and it is cheap, and an event whose id does
      // not describe its own contents is not worth a scalar multiplication.
      final digest = await _sha256.hash(utf8.encode(r.serialized));
      if (_hex(digest.bytes) != r.idHex) return false;
      return await Secp256k1.verify(
        publicKey: _unhex(r.pubkeyHex),
        message: _unhex(r.idHex),
        signature: _unhex(r.sigHex),
      );
    } catch (_) {
      // Malformed hex, a bad point, anything: not ours, and a relay is allowed
      // to hand us rubbish.
      return false;
    }
  }

  static String _hex(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  static Uint8List _unhex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

class _VerifyRequest {
  const _VerifyRequest({
    required this.serialized,
    required this.idHex,
    required this.pubkeyHex,
    required this.sigHex,
  });

  final String serialized;
  final String idHex;
  final String pubkeyHex;
  final String sigHex;
}
