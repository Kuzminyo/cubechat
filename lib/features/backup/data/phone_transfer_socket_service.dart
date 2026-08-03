import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_service.dart';

class PhoneTransferPayload {
  const PhoneTransferPayload({
    required this.host,
    required this.port,
    required this.token,
    required this.password,
  });

  static const prefix = 'cubechat:t1:';

  final String host;
  final int port;
  final String token;
  final String password;

  String encode() =>
      prefix +
      base64Url
          .encode(utf8.encode(jsonEncode({
            'host': host,
            'port': port,
            'token': token,
            'password': password,
          })))
          .replaceAll('=', '');

  static PhoneTransferPayload? tryDecode(String raw) {
    if (!raw.startsWith(prefix)) return null;
    try {
      final encoded = raw.substring(prefix.length);
      final padding = '=' * ((4 - encoded.length % 4) % 4);
      final dynamic value =
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
          token.length < 20 ||
          password.length < 20) {
        return null;
      }
      return PhoneTransferPayload(
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

class PhoneTransferSession {
  PhoneTransferSession({
    required this.payload,
    required this.bytes,
    required ServerSocket server,
    required StreamSubscription<Socket> subscription,
  })  : _server = server,
        _subscription = subscription;

  final String payload;
  final int bytes;
  final ServerSocket _server;
  final StreamSubscription<Socket> _subscription;

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
  }
}

/// One-use local TCP transfer. The payload is an AES-GCM encrypted backup;
/// the random decryption password and connection token exist only in the QR.
class PhoneTransferService {
  PhoneTransferService(this._ref);

  static const maxTransferBytes = 128 * 1024 * 1024;

  final Ref _ref;
  final Random _random = Random.secure();

  Future<PhoneTransferSession> startSending() async {
    final token = _randomText(24);
    final password = _randomText(32);
    final encrypted = await _ref.read(backupServiceProvider).create(
          password: password,
        );
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final host = await _localIpv4();
    if (host == null) {
      await server.close();
      throw StateError('Connect both phones to the same Wi-Fi network');
    }
    final payload = PhoneTransferPayload(
      host: host,
      port: server.port,
      token: token,
      password: password,
    );

    late final StreamSubscription<Socket> serverSubscription;
    var consumed = false;
    serverSubscription = server.listen((socket) {
      if (consumed) {
        socket.destroy();
        return;
      }
      final auth = BytesBuilder(copy: false);
      late final StreamSubscription<Uint8List> socketSubscription;
      socketSubscription = socket.listen(
        (chunk) async {
          if (consumed) return;
          auth.add(chunk);
          if (auth.length < token.length) return;
          await socketSubscription.cancel();
          final candidate = utf8.decode(
            auth.takeBytes().take(token.length).toList(),
            allowMalformed: true,
          );
          if (candidate != token) {
            socket.destroy();
            return;
          }
          consumed = true;
          socket.add(encrypted);
          await socket.flush();
          await socket.close();
          await serverSubscription.cancel();
          await server.close();
        },
        onError: (_) => socket.destroy(),
        onDone: socket.destroy,
        cancelOnError: true,
      );
    });

    return PhoneTransferSession(
      payload: payload.encode(),
      bytes: encrypted.length,
      server: server,
      subscription: serverSubscription,
    );
  }

  Future<void> receive(PhoneTransferPayload payload) async {
    final socket = await Socket.connect(
      payload.host,
      payload.port,
      timeout: const Duration(seconds: 12),
    );
    final builder = BytesBuilder(copy: false);
    var received = 0;
    try {
      socket.add(utf8.encode(payload.token));
      await socket.flush();
      await for (final chunk in socket.timeout(const Duration(seconds: 20))) {
        received += chunk.length;
        if (received > maxTransferBytes) {
          throw const FormatException('transfer is too large');
        }
        builder.add(chunk);
      }
      if (received == 0) throw StateError('The transfer link has expired');
      await _ref.read(backupServiceProvider).restore(
            builder.takeBytes(),
            password: payload.password,
          );
    } finally {
      socket.destroy();
    }
  }

  Future<String?> _localIpv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final host = address.address;
        fallback ??= host;
        if (host.startsWith('10.') ||
            host.startsWith('192.168.') ||
            RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) {
          return host;
        }
      }
    }
    return fallback;
  }

  String _randomText(int bytes) {
    final values = List<int>.generate(bytes, (_) => _random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }
}

final phoneTransferServiceProvider =
    Provider<PhoneTransferService>(PhoneTransferService.new);
