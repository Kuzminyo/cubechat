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
  /// On cubechat.tech, which the app claims for `/l1` — so Google Lens on the
  /// phone opens the app with the code, the same as `t1`.
  static const linkPrefix = 'https://cubechat.tech/l1#';

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
    raw = transferCodeText(raw);
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
          !isLocalNetworkHost(host) ||
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

/// Whether [uri] carries a transfer (`t1`) or a computer sign-in (`l1`) code —
/// a link the app opens into the scanner rather than as a contact or a name.
bool isTransferLink(Uri uri) {
  final text = transferCodeText(uri.toString());
  return text.contains(DesktopLinkPayload.prefix) ||
      text.contains(PhoneTransferPayload.prefix);
}

/// One code on the computer's screen, waiting for one phone.
class DesktopLinkSession {
  DesktopLinkSession._(this.qr, this._server, this._done, this._sockets);

  /// What to draw as the QR code.
  final String qr;
  final ServerSocket _server;
  final Completer<void> _done;
  final Set<Socket> _sockets;

  /// Completes once a phone's copy has been restored here, or with the error
  /// that stopped it.
  Future<void> get done => _done.future;

  Future<void> cancel() async {
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
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
    required Future<void> Function(File destination, String password)
        createBackup,
    required Future<void> Function(File source, String password) restoreBackup,
    Future<String?> Function()? localHost,
    Future<File> Function(String role)? tempFile,
  })  : _createBackup = createBackup,
        _restoreBackup = restoreBackup,
        _localHost = localHost ?? localNetworkIpv4,
        _tempFile = tempFile ?? transferTempFile;

  final Future<void> Function(File destination, String password) _createBackup;
  final Future<void> Function(File source, String password) _restoreBackup;
  final Future<String?> Function() _localHost;
  final Future<File> Function(String role) _tempFile;

  static const int _ok = 0x01;
  static const int _failed = 0x00;

  /// Restoring a copy with photos in it takes a while; the phone waits for
  /// the answer this long before calling it lost.
  static const Duration _restoreWait = Duration(minutes: 10);

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
    final headLength = tokenBytes.length + 8;
    var consumed = false;
    final sockets = <Socket>{};
    server.listen((socket) async {
      if (consumed) {
        socket.destroy();
        return;
      }
      sockets.add(socket);
      // The copy goes to a file as it arrives — a phone with a gallery is
      // gigabytes, and none of it is held in memory here.
      final head = BytesBuilder(copy: false);
      var length = -1;
      var written = 0;
      RandomAccessFile? sink;
      File? archive;
      var ownsTransfer = false;
      try {
        await for (final chunk in socket.timeout(const Duration(seconds: 30))) {
          var rest = chunk;
          if (length < 0) {
            head.add(chunk);
            if (head.length < headLength) continue;
            final bytes = head.takeBytes();
            for (var i = 0; i < tokenBytes.length; i++) {
              if (bytes[i] != tokenBytes[i]) {
                socket.destroy();
                return;
              }
            }
            length = ByteData.sublistView(bytes, tokenBytes.length, headLength)
                .getUint64(0);
            if (length <= 0 || length > PhoneTransferService.maxTransferBytes) {
              socket.destroy();
              return;
            }
            if (consumed) {
              socket.destroy();
              return;
            }
            // Used up once a phone has proved it read this screen: a second
            // phone must not land on top of the first one's copy.
            consumed = true;
            ownsTransfer = true;
            archive = await _tempFile('link');
            sink = await archive.open(mode: FileMode.write);
            rest = Uint8List.sublistView(bytes, headLength);
          }
          final take = min(rest.length, length - written);
          if (take > 0) {
            await sink!.writeFrom(rest, 0, take);
            written += take;
          }
          if (written >= length) break;
        }
        if (length < 0 || written < length) {
          throw const FormatException(
            'The transfer ended before the copy arrived',
          );
        }
        await sink!.close();
        sink = null;
        if (done.isCompleted) return;
        try {
          await _restoreBackup(archive!, payload.password);
          socket.add([_ok]);
          await socket.flush();
          if (!done.isCompleted) done.complete();
        } catch (e) {
          socket.add([_failed]);
          await socket.flush();
          if (!done.isCompleted) done.completeError(e);
        }
        await socket.close();
        await server.close();
      } catch (error) {
        socket.destroy();
        if (ownsTransfer && !done.isCompleted) done.completeError(error);
      } finally {
        await sink?.close();
        sockets.remove(socket);
        if (ownsTransfer) await server.close();
        try {
          if (archive != null && await archive.exists()) {
            await archive.delete();
          }
        } catch (_) {}
      }
    });
    return DesktopLinkSession._(payload.encode(), server, done, sockets);
  }

  /// The phone's side: send a copy of this account to the computer behind
  /// [payload], and return once the computer says it is restored.
  Future<void> sendTo(DesktopLinkPayload payload) async {
    final archive = await _tempFile('link-send');
    try {
      await _createBackup(archive, payload.password);
      final size = await archive.length();
      if (size <= 0 || size > PhoneTransferService.maxTransferBytes) {
        throw const FormatException('transfer is too large or empty');
      }
      final socket = await Socket.connect(
        payload.host,
        payload.port,
        timeout: const Duration(seconds: 12),
      );
      try {
        final length = ByteData(8)..setUint64(0, size);
        socket
          ..add(ascii.encode(payload.token))
          ..add(length.buffer.asUint8List());
        await socket.addStream(archive.openRead());
        await socket.flush();
        // Closed with no answer at all: a wrong or used-up code.
        final answer = await socket.timeout(_restoreWait).firstWhere(
              (chunk) => chunk.isNotEmpty,
              orElse: () => Uint8List(0),
            );
        if (answer.isEmpty) {
          throw StateError('The computer did not accept this code');
        }
        if (answer.first != _ok) {
          throw StateError('The computer could not restore the copy');
        }
      } on SocketException {
        throw StateError('The computer did not accept this code');
      } finally {
        socket.destroy();
      }
    } finally {
      try {
        if (await archive.exists()) await archive.delete();
      } catch (_) {}
    }
  }

  String _randomText(int bytes) => base64Url
      .encode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
}

final desktopLinkServiceProvider = Provider<DesktopLinkService>(
  (ref) => DesktopLinkService(
    createBackup: (file, password) =>
        ref.read(backupServiceProvider).createFile(file, password: password),
    restoreBackup: (file, password) =>
        ref.read(backupServiceProvider).restoreFile(file, password: password),
  ),
);
