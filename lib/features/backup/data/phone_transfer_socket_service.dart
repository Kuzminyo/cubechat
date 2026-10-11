import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

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

  /// Wrapped in an https link so a scanner that has never heard of cubechat —
  /// Google Lens, the iOS camera — has something it knows how to open. The
  /// token stays in the *fragment*, the one part of a URL a browser never
  /// sends to a server, so the address and password of a transfer in progress
  /// never leave the two phones even if the link is opened in a browser.
  ///
  /// The old `cubechat:t1:` token is kept inside the link rather than replaced
  /// by it, so the string carries both readings at once.
  ///
  /// On cubechat.tech since 1141 — our own site, which the app claims as an
  /// App Link for `/t1`, so Google Lens opens the app with it. It was
  /// `cubechat.app`, a domain nobody here holds, and Lens sent the code to a
  /// browser tab that went nowhere. Old codes still read: the token is found
  /// by search, wherever it sits.
  static const linkPrefix = 'https://cubechat.tech/t1#';

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

  static PhoneTransferPayload? tryDecode(String raw) {
    raw = transferCodeText(raw);
    // Found by search rather than required at the front: the token now travels
    // inside an https link, and a scanner may hand back the URL with anything
    // around it.
    final at = raw.indexOf(prefix);
    if (at < 0) return null;
    try {
      final encoded = raw.substring(at + prefix.length).trim();
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
          !isLocalNetworkHost(host) ||
          port < 1 ||
          port > 65535 ||
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
    required File archive,
    required Set<Socket> sockets,
  })  : _server = server,
        _subscription = subscription,
        _archive = archive,
        _sockets = sockets;

  final String payload;
  final int bytes;
  final ServerSocket _server;
  final StreamSubscription<Socket> _subscription;
  final File _archive;
  final Set<Socket> _sockets;

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _subscription.cancel();
    await _server.close();
    try {
      if (await _archive.exists()) await _archive.delete();
    } catch (_) {
      // A temp file the system clears on its own.
    }
  }
}

/// One-use local TCP transfer. The payload is an encrypted backup; the random
/// decryption password and connection token exist only in the QR.
///
/// Streamed through a file at both ends since 1141. It used to be built and
/// received whole in memory, which capped the photos and videos it could carry
/// at 48 MB — "Use a file backup: media exceeds the phone transfer budget" on
/// the first phone that had a gallery worth moving (2026-10-10). The file
/// backup ([BackupService.createFile]) streams media in authenticated records
/// and has no such cap, so the transfer now sends that file as it is.
class PhoneTransferService {
  PhoneTransferService(Ref ref)
      : this.withCallbacks(
          createBackup: (file, password) => ref
              .read(backupServiceProvider)
              .createFile(file, password: password),
          restoreBackup: (file, password) => ref
              .read(backupServiceProvider)
              .restoreFile(file, password: password),
        );

  PhoneTransferService.withCallbacks({
    required Future<void> Function(File, String) createBackup,
    required Future<void> Function(File, String) restoreBackup,
    Future<String?> Function()? localHost,
    Future<File> Function(String)? tempFile,
  })  : _createBackup = createBackup,
        _restoreBackup = restoreBackup,
        _localHost = localHost ?? localNetworkIpv4,
        _tempFile = tempFile ?? transferTempFile;

  /// A ceiling against a stream that never ends, not a budget anybody meets.
  static const maxTransferBytes = 16 * 1024 * 1024 * 1024;

  final Future<void> Function(File, String) _createBackup;
  final Future<void> Function(File, String) _restoreBackup;
  final Future<String?> Function() _localHost;
  final Future<File> Function(String) _tempFile;
  final Random _random = Random.secure();

  Future<PhoneTransferSession> startSending() async {
    final token = _randomText(24);
    final password = _randomText(32);
    final archive = await _tempFile('send');
    try {
      await _createBackup(archive, password);
    } catch (_) {
      if (await archive.exists()) await archive.delete();
      rethrow;
    }
    final size = await archive.length();
    final host = await _localHost();
    if (host == null || size <= 0 || size > maxTransferBytes) {
      await archive.delete();
      throw StateError(
        host == null
            ? 'Connect both phones to the same Wi-Fi network'
            : 'transfer is too large or empty',
      );
    }
    late final ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {
      await archive.delete();
      rethrow;
    }
    final payload = PhoneTransferPayload(
      host: host,
      port: server.port,
      token: token,
      password: password,
    );

    late final StreamSubscription<Socket> serverSubscription;
    var consumed = false;
    final sockets = <Socket>{};
    serverSubscription = server.listen((socket) {
      if (consumed) {
        socket.destroy();
        return;
      }
      final auth = BytesBuilder(copy: false);
      sockets.add(socket);
      late final StreamSubscription<Uint8List> socketSubscription;
      socketSubscription = socket.timeout(const Duration(seconds: 30)).listen(
        (chunk) async {
          if (consumed) return;
          auth.add(chunk);
          if (auth.length < token.length) return;
          await socketSubscription.cancel();
          final candidate = utf8.decode(
            auth.takeBytes().take(token.length).toList(),
            allowMalformed: true,
          );
          if (candidate != token || consumed) {
            socket.destroy();
            return;
          }
          consumed = true;
          try {
            await socket.addStream(archive.openRead());
            await socket.flush();
            await socket.close();
          } catch (_) {
            socket.destroy();
          } finally {
            sockets.remove(socket);
            await serverSubscription.cancel();
            await server.close();
          }
        },
        onError: (_) {
          sockets.remove(socket);
          socket.destroy();
        },
        onDone: () {
          sockets.remove(socket);
          socket.destroy();
        },
        cancelOnError: true,
      );
    });

    return PhoneTransferSession(
      payload: payload.encode(),
      bytes: size,
      server: server,
      subscription: serverSubscription,
      archive: archive,
      sockets: sockets,
    );
  }

  Future<void> receive(PhoneTransferPayload payload) async {
    final socket = await Socket.connect(
      payload.host,
      payload.port,
      timeout: const Duration(seconds: 12),
    );
    File? archive;
    var received = 0;
    try {
      archive = await _tempFile('receive');
      socket.add(utf8.encode(payload.token));
      await socket.flush();
      final sink = await archive.open(mode: FileMode.write);
      try {
        await for (final chunk in socket.timeout(const Duration(seconds: 30))) {
          received += chunk.length;
          if (received > maxTransferBytes) {
            throw const FormatException('transfer is too large');
          }
          await sink.writeFrom(chunk);
        }
      } finally {
        await sink.close();
      }
      if (received == 0) throw StateError('The transfer link has expired');
      await _restoreBackup(archive, payload.password);
    } finally {
      socket.destroy();
      try {
        if (archive != null && await archive.exists()) await archive.delete();
      } catch (_) {}
    }
  }

  String _randomText(int bytes) {
    final values = List<int>.generate(bytes, (_) => _random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }
}

/// Whether [host] is somewhere on this device's own network: a private range,
/// link-local, or loopback.
///
/// A transfer code says where to connect, and a code can arrive on a web page
/// or in a chat as well as on a screen across the table. Both devices of a
/// transfer are on one Wi-Fi, so an address anywhere else is somebody else's
/// server — and the next step is sending it, or taking from it, a whole
/// account. Refused when the code is read, not when it is used.
bool isLocalNetworkHost(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255 || '$n' != part) return false;
    octets.add(n);
  }
  final (a, b) = (octets[0], octets[1]);
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}

/// Browser hand-off links can wrap the original code in an escaped fragment
/// or the legacy `c` parameter. Decode once, without sending it to a server.
String transferCodeText(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  try {
    final code = uri.queryParameters['c'];
    if (code != null) return code;
    if (uri.hasFragment) return Uri.decodeComponent(uri.fragment);
  } on FormatException {
    return raw;
  }
  return raw;
}

final phoneTransferServiceProvider =
    Provider<PhoneTransferService>(PhoneTransferService.new);

/// This device's best address on the local network — what a phone or a
/// computer on the same Wi-Fi can connect to. See [orderLocalAddresses].
Future<String?> localNetworkIpv4() async {
  final addresses = await localNetworkAddresses();
  return addresses.isEmpty ? null : addresses.first;
}

/// Every private address this device has, the likeliest to be reachable from
/// another device on the same Wi-Fi first.
Future<List<String>> localNetworkAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  return orderLocalAddresses([
    for (final interface in interfaces)
      for (final address in interface.addresses)
        (name: interface.name, address: address.address),
  ]);
}

/// Private addresses only, the real network first and virtual adapters last.
///
/// The system lists adapters in no useful order. A Windows computer with
/// VirtualBox, Hyper-V and WSL had four private addresses on 2026-10-11 and
/// Wi-Fi was the second: taking the first private one put VirtualBox's
/// host-only 192.168.56.1 in the sign-in code, and no phone could ever reach
/// it. Nothing is dropped — an adapter may be named in a way this does not
/// recognise — it is only ranked, and the code carries several.
List<String> orderLocalAddresses(
  Iterable<({String name, String address})> adapters,
) {
  int rank(({String name, String address}) a) {
    final name = a.name.toLowerCase();
    if (a.address.startsWith('169.254.')) return 3; // no DHCP answered
    if (a.address.startsWith('192.168.56.')) return 2; // VirtualBox host-only
    const virtual = [
      'vethernet', 'wsl', 'hyper-v', 'virtualbox', 'vbox', 'vmware', 'vmnet',
      'docker', 'veth', 'br-', 'bridge', 'tun', 'tap', 'utun', 'zerotier',
      'tailscale', 'wireguard', 'npcap', 'loopback',
      // Mobile data on a phone: a carrier's 10.x is private, and useless here.
      'rmnet', 'ccmni', 'pdp_ip', 'clat',
    ];
    if (virtual.any(name.contains)) return 2;
    const wireless = [
      'wi-fi', 'wifi', 'wlan', 'wireless', 'swlan', 'ap0',
      'беспровод', 'бездротов', // Windows in Russian and Ukrainian
    ];
    if (wireless.any(name.contains)) return 0;
    return 1;
  }

  final private = [
    for (final a in adapters)
      if (isLocalNetworkHost(a.address) && !a.address.startsWith('127.')) a,
  ];
  // A stable sort: within a rank the system's own order stands.
  final indexed = [for (var i = 0; i < private.length; i++) (i, private[i])]
    ..sort((x, y) {
      final byRank = rank(x.$2).compareTo(rank(y.$2));
      return byRank != 0 ? byRank : x.$1.compareTo(y.$1);
    });
  final seen = <String>{};
  return [
    for (final (_, a) in indexed)
      if (seen.add(a.address)) a.address,
  ];
}

/// A private temporary file for one transfer's archive.
Future<File> transferTempFile(String role) async {
  final dir = await getTemporaryDirectory();
  return File(
    '${dir.path}${Platform.pathSeparator}'
    'cubechat-transfer-$role-${DateTime.now().microsecondsSinceEpoch}.bin',
  );
}
