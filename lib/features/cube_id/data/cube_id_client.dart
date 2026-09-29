import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/transport/nostr/nostr_event.dart';
import '../../../core/util/debug_log.dart';
import '../domain/cube_name.dart';

/// One HTTP exchange with the Cube ID server; `status` is `-1` when nothing
/// answered at all — the same "never throws" contract as `ReportPoster`.
typedef CubeIdHttp = Future<({int status, String body})> Function(
  String method,
  Uri uri, {
  String? body,
});

sealed class CubeIdResult {
  const CubeIdResult();
}

class CubeIdOk extends CubeIdResult {
  const CubeIdOk(this.name);
  final String? name;
}

class CubeIdRefused extends CubeIdResult {
  const CubeIdRefused(this.code);

  /// The server's `error`: taken, reserved, invalid, has-name, pow, stale,
  /// card-mismatch, card-invalid, rate, no-name, bad-signature, bad-request.
  final String code;
}

class CubeIdOffline extends CubeIdResult {
  const CubeIdOffline();
}

Future<({int status, String body})> _defaultHttp(
  String method,
  Uri uri, {
  String? body,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.openUrl(method, uri);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, body: text);
  } catch (e) {
    DebugLog.instance.log('CUBEID', '${uri.host} did not answer: $e');
    return (status: -1, body: '');
  } finally {
    client.close(force: true);
  }
}

class CubeIdClient {
  CubeIdClient({CubeIdHttp? http, String base = 'https://$cubeIdHost'})
      : _http = http ?? _defaultHttp,
        _base = Uri.parse(base);

  final CubeIdHttp _http;
  final Uri _base;

  Uri _at(String path) => _base.replace(path: path);

  Future<CubeIdResult> send(NostrEvent event) async {
    final r = await _http(
      'POST',
      _at('/v1/op'),
      body: jsonEncode(event.toJson()),
    );
    if (r.status == 200) {
      final name = _json(r.body)['name'];
      return CubeIdOk(name is String ? name : null);
    }
    if (r.status == -1 || r.status >= 500) return const CubeIdOffline();
    final code = _json(r.body)['error'];
    return CubeIdRefused(code is String ? code : 'http-${r.status}');
  }

  /// Null when the server did not answer.
  Future<({bool available, String? reason})?> available(String raw) async {
    final name = normalizeCubeName(raw);
    final r = await _http(
      'GET',
      _at('/v1/available/${Uri.encodeComponent(name)}'),
    );
    if (r.status != 200) return null;
    final json = _json(r.body);
    final reason = json['reason'];
    return (
      available: json['available'] == true,
      reason: reason is String ? reason : null,
    );
  }

  /// The raw announcement bytes behind [raw], or null for not found, no
  /// answer, or a body that is not base64url. Not verified here — the caller
  /// verifies the signature, exactly as for a card from a QR code.
  Future<Uint8List?> card(String raw) async {
    final name = normalizeCubeName(raw);
    final r = await _http('GET', _at('/v1/card/${Uri.encodeComponent(name)}'));
    if (r.status != 200) return null;
    final card = _json(r.body)['card'];
    if (card is! String) return null;
    try {
      return base64Url.decode(base64Url.normalize(card));
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _json(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : const {};
    } on FormatException {
      return const {};
    }
  }
}
