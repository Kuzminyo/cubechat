import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_service.dart';
import 'phone_transfer_socket_service.dart';

/// What the computer shows and the phone scans: where to send the copy, the
/// token that proves the phone read this screen, and the password the copy is
/// encrypted under.
///
/// A kind of its own, `cubechat:l1:`, beside the phone-to-phone `t1:` — the
/// two go in opposite directions, and a phone must never mistake "give your
/// account to this screen" for "take the account this screen is offering".
class DesktopLinkPayload {
  const DesktopLinkPayload({
    required this.host,
    required this.port,
    required this.token,
    required this.password,
  });

  static const prefix = 'cubechat:l1:';

  /// An https link for scanners that know nothing of cubechat, with the token
  /// in the fragment, which a browser never sends anywhere — as `t1` does.
  static const linkPrefix = 'https://cubechat.app/l1#';

  /// Shortest token or password a code may carry; both are minted at 24 and
  /// 32 random bytes.
  static const minSecret = 20;

  final String host;
  final int port;
  final String token;
  final String password;

  String encode() =>
      linkPrefix +
      prefix +
      base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'host': host,
                'port': port,
                'token': token,
                'password': password,
              }),
            ),
          )
          .replaceAll('=', '');

  static DesktopLinkPayload? tryDecode(String raw) {
    final at = raw.indexOf(prefix);
    if (at < 0) return null;
    try {
      final encoded = raw.substring(at + prefix.length).trim();
      final padding = '=' * ((4 - encoded.length % 4) % 4);
      final Object? value =
          jsonDecode(utf8.decode(base64Url.decode(encoded + padding)));
      if (value is! Map<String, dynamic>) return null;
      final host = value['host'];
      final port = value['port'];
      final token = value['token'];
      final password = value['password'];
      if (host is! String ||
          port is! int ||
          token is! String ||
          password is! String ||
          port < 1 ||
          port > 0xFFFF ||
          token.length < minSecret ||
          password.length < minSecret) {
        return null;
      }
      return DesktopLinkPayload(
        host: host,
        port: port,
        token: token,
        password: password,
      );
    } catch (_) {
      return null;
    }
  }
}

/// One code on the computer's screen, waiting for one phone.
class DesktopLinkSession {
  DesktopLinkSession._(this.qr, this._server, this._done);

  /// What to draw as the QR code.
  final String qr;
  final ServerSocket _server;
  final Completer<void> _done;

  /// Completes once a phone's copy has been restored here, or with the error
  /// that stopped it.
  Future<void> get done => _done.future;

  Future<void> cancel() async {
    await _server.close();
    if (!_done.isCompleted) {
      _done.completeError(StateError('cancelled'));
    }
  }
}

/// Moves a copy of the phone's account onto a computer. The phone keeps
/// working: nothing is wiped or changed on it.
///
/// Wire, on one TCP connection: the phone writes the token, an 8-byte
/// big-endian length, then the encrypted copy; the computer answers one byte,
/// [_ok] once the copy is restored. A wrong token closes the connection and
/// leaves the code waiting for the right phone; the first right one uses it up.
class DesktopLinkService {
  DesktopLinkService({
    required Future<Uint8List> Function(String password) createBackup,
    required Future<void> Function(Uint8List bytes, String password)
        restoreBackup,
    Future<String?> Function()? localHost,
  })  : _createBackup = createBackup,
        _restoreBackup = restoreBackup,
        _localHost = localHost ?? localNetworkIpv4;

  final Future<Uint8List> Function(String password) _createBackup;
  final Future<void> Function(Uint8List bytes, String password) _restoreBackup;
  final Future<String?> Function() _localHost;

  static const int _ok = 0x01;
  static const int _failed = 0x00;

  /// Restoring a copy with photos in it takes a while; the phone waits for
  /// the answer this long before calling it lost.
  static const Duration _restoreWait = Duration(minutes: 5);

  final Random _random = Random.secure();

  /// The computer's side: serve once, and show [DesktopLinkSession.qr].
  Future<DesktopLinkSession> startReceiving() async {
    final host = await _localHost();
    if (host == null) {
      throw StateError('Connect the computer to a network first');
    }
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final payload = DesktopLinkPayload(
      host: host,
      port: server.port,
      token: _randomText(24),
      password: _randomText(32),
    );
    final done = Completer<void>();
    final tokenBytes = ascii.encode(payload.token);
    var consumed = false;
    server.listen((socket) {
      if (consumed) {
        socket.destroy();
        return;
      }
      final buffer = BytesBuilder(copy: false);
      var length = -1;
      var handled = false;
      late final StreamSubscription<Uint8List> sub;
      sub = socket.listen(
        (chunk) async {
          if (handled) return;
          buffer.add(chunk);
          final have = buffer.length;
          if (length < 0) {
            if (have < tokenBytes.length + 8) return;
            final head = buffer.toBytes();
            for (var i = 0; i < tokenBytes.length; i++) {
              if (head[i] != tokenBytes[i]) {
                handled = true;
                socket.destroy();
                return;
              }
            }
            length = ByteData.sublistView(head, tokenBytes.length)
                .getUint64(0);
            if (length <= 0 || length > PhoneTransferService.maxTransferBytes) {
              handled = true;
              socket.destroy();
              return;
            }
          }
          final start = tokenBytes.length + 8;
          if (have < start + length) return;
          handled = true;
          // Used up before the restore starts: a second phone scanning the
          // same screen must not land on top of the first one's copy.
          consumed = true;
          await sub.cancel();
          final body = Uint8List.sublistView(
            buffer.takeBytes(),
            start,
            start + length,
          );
          try {
            await _restoreBackup(body, payload.password);
            socket.add([_ok]);
            await socket.flush();
            if (!done.isCompleted) done.complete();
          } catch (e) {
            socket.add([_failed]);
            await socket.flush();
            if (!done.isCompleted) done.completeError(e);
          } finally {
            await socket.close();
            await server.close();
          }
        },
        onError: (_) => socket.destroy(),
        cancelOnError: true,
      );
    });
    return DesktopLinkSession._(payload.encode(), server, done);
  }

  /// The phone's side: send a copy of this account to the computer behind
  /// [payload], and return once the computer says it is restored.
  Future<void> sendTo(DesktopLinkPayload payload) async {
    final copy = await _createBackup(payload.password);
    if (copy.length > PhoneTransferService.maxTransferBytes) {
      throw StateError(
        'This account is ${copy.length ~/ (1024 * 1024)} MB, over the '
        '${PhoneTransferService.maxTransferBytes ~/ (1024 * 1024)} MB a '
        'transfer carries',
      );
    }
    final socket = await Socket.connect(
      payload.host,
      payload.port,
      timeout: const Duration(seconds: 12),
    );
    try {
      final length = ByteData(8)..setUint64(0, copy.length);
      socket
        ..add(ascii.encode(payload.token))
        ..add(length.buffer.asUint8List())
        ..add(copy);
      await socket.flush();
      final answer = await socket.first.timeout(_restoreWait);
      if (answer.isEmpty || answer.first != _ok) {
        throw StateError('The computer could not restore the copy');
      }
    } on StateError {
      rethrow;
    } catch (e) {
      // A closed connection with no answer: a wrong or used-up code.
      throw StateError('The computer did not accept this code ($e)');
    } finally {
      socket.destroy();
    }
  }

  String _randomText(int bytes) => base64Url
      .encode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
}

final desktopLinkServiceProvider = Provider<DesktopLinkService>(
  (ref) => DesktopLinkService(
    createBackup: (password) =>
        ref.read(backupServiceProvider).create(password: password),
    restoreBackup: (bytes, password) =>
        ref.read(backupServiceProvider).restore(bytes, password: password),
  ),
);
