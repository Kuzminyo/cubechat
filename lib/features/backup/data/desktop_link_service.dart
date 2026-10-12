import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/debug_log.dart';
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
    this.hosts = const [],
  });

  static const prefix = 'cubechat:l1:';

  /// How many addresses a code may name — enough for Wi-Fi beside a few
  /// virtual adapters, few enough to keep the QR easy to scan.
  static const maxHosts = 4;

  /// An https link for scanners that know nothing of cubechat, with the token
  /// in the fragment, which a browser never sends anywhere — as `t1` does.
  /// On cubechat.tech, which the app claims for `/l1` — so Google Lens on the
  /// phone opens the app with the code, the same as `t1`.
  static const linkPrefix = 'https://cubechat.tech/l1#';

  /// Shortest token or password a code may carry; both are minted at 24 and
  /// 32 random bytes.
  static const minSecret = 20;

  /// The best address — the only one builds before 1142 read.
  final String host;
  final int port;
  final String token;
  final String password;

  /// Every address the computer can be reached on, best first. A computer
  /// with VirtualBox, Hyper-V or WSL has several private addresses and only
  /// one of them is on the phone's Wi-Fi; which one cannot be told from the
  /// computer's side for certain, so the phone tries them all.
  final List<String> hosts;

  /// Where the phone should try to connect: [hosts], or [host] in a code from
  /// an older build.
  List<String> get candidates => hosts.isEmpty ? [host] : hosts;

  String encode() =>
      linkPrefix +
      prefix +
      base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'host': host,
                if (hosts.isNotEmpty) 'hosts': hosts,
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
      // Each address is checked as [host] is: one off the local network
      // makes the whole code a stranger's.
      final rawHosts = value['hosts'];
      final hosts = <String>[];
      if (rawHosts != null) {
        if (rawHosts is! List || rawHosts.length > maxHosts) return null;
        for (final h in rawHosts) {
          if (h is! String || !isLocalNetworkHost(h)) return null;
          hosts.add(h);
        }
      }
      return DesktopLinkPayload(
        host: host,
        port: port,
        token: token,
        password: password,
        hosts: hosts,
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

/// Where a sign-in is, as either side shows it.
///
/// Reported on 2026-10-12: the computer said "waiting for the phone" while the
/// phone said "sending", and that is all either said for minutes — through
/// the phone making a copy that holds every photo, the copy crossing the
/// Wi-Fi, and the computer restoring it. It looked hung at every step.
enum LinkStage {
  /// The code is on screen and nobody has dialled in.
  waiting,

  /// Phone: looking for the computer. Computer: a phone has found it.
  connecting,

  /// Phone: making the encrypted copy. The long step with a gallery.
  preparing,

  /// The copy crossing the network; [LinkProgress.fraction] says how much.
  transferring,

  /// The computer putting the copy in place.
  restoring,
}

@immutable
class LinkProgress {
  const LinkProgress(this.stage, [this.fraction = 0]);

  final LinkStage stage;

  /// 0..1 of the copy sent or received, while [stage] is
  /// [LinkStage.transferring].
  final double fraction;
}

/// One code on the computer's screen, waiting for one phone.
class DesktopLinkSession {
  DesktopLinkSession._(
    this.qr,
    this._server,
    this._done,
    this._sockets,
    this._progress,
  );

  /// What to draw as the QR code.
  final String qr;
  final ServerSocket _server;
  final Completer<void> _done;
  final Set<Socket> _sockets;
  final ValueNotifier<LinkProgress> _progress;

  /// Which step the sign-in is on, for the screen to say.
  ValueListenable<LinkProgress> get progress => _progress;

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
    Future<List<String>> Function()? localHosts,
    Future<File> Function(String role)? tempFile,
  })  : _createBackup = createBackup,
        _restoreBackup = restoreBackup,
        _localHosts = localHosts ?? localNetworkAddresses,
        _tempFile = tempFile ?? transferTempFile;

  final Future<void> Function(File destination, String password) _createBackup;
  final Future<void> Function(File source, String password) _restoreBackup;
  final Future<List<String>> Function() _localHosts;
  final Future<File> Function(String role) _tempFile;

  static const int _ok = 0x01;
  static const int _failed = 0x00;

  /// Restoring a copy with photos in it takes a while; the phone waits for
  /// the answer this long before calling it lost.
  static const Duration _restoreWait = Duration(minutes: 10);

  final Random _random = Random.secure();

  /// The computer's side: serve once, and show [DesktopLinkSession.qr].
  Future<DesktopLinkSession> startReceiving() async {
    final hosts = (await _localHosts())
        .take(DesktopLinkPayload.maxHosts)
        .toList();
    if (hosts.isEmpty) {
      throw StateError('Connect the computer to a network first');
    }
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final payload = DesktopLinkPayload(
      host: hosts.first,
      hosts: hosts.length > 1 ? hosts : const [],
      port: server.port,
      token: _randomText(24),
      password: _randomText(32),
    );
    final done = Completer<void>();
    final tokenBytes = ascii.encode(payload.token);
    final headLength = tokenBytes.length + 8;
    var consumed = false;
    final sockets = <Socket>{};
    final progress = ValueNotifier(const LinkProgress(LinkStage.waiting));
    server.listen((socket) async {
      if (consumed) {
        socket.destroy();
        return;
      }
      sockets.add(socket);
      // The phone dials once to find this computer before it spends minutes
      // on the copy, and that first call carries nothing. It is still the
      // first sign that the phone and the network both work.
      if (progress.value.stage == LinkStage.waiting) {
        progress.value = const LinkProgress(LinkStage.connecting);
        DebugLog.instance.log('LINK', 'a phone reached this computer');
      }
      var shownPercent = -1;
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
            DebugLog.instance.log('LINK', 'receiving a copy of $length bytes');
            progress.value = const LinkProgress(LinkStage.transferring);
            archive = await _tempFile('link');
            sink = await archive.open(mode: FileMode.write);
            rest = Uint8List.sublistView(bytes, headLength);
          }
          final take = min(rest.length, length - written);
          if (take > 0) {
            await sink!.writeFrom(rest, 0, take);
            written += take;
          }
          // Whole percents: a notifier per socket chunk would rebuild the
          // screen thousands of times for a gallery.
          final percent = written * 100 ~/ length;
          if (percent != shownPercent) {
            shownPercent = percent;
            progress.value =
                LinkProgress(LinkStage.transferring, written / length);
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
        progress.value = const LinkProgress(LinkStage.restoring);
        try {
          await _restoreBackup(archive!, payload.password);
          DebugLog.instance.log('LINK', 'the copy is restored');
          socket.add([_ok]);
          await socket.flush();
          if (!done.isCompleted) done.complete();
        } catch (e) {
          DebugLog.instance.log('LINK', 'restoring failed: ${e.runtimeType}');
          socket.add([_failed]);
          await socket.flush();
          if (!done.isCompleted) done.completeError(e);
        }
        await socket.close();
        await server.close();
      } catch (error) {
        socket.destroy();
        if (ownsTransfer) {
          DebugLog.instance.log('LINK', 'receiving failed: ${error.runtimeType}');
          if (!done.isCompleted) done.completeError(error);
        }
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
    return DesktopLinkSession._(
      payload.encode(),
      server,
      done,
      sockets,
      progress,
    );
  }

  /// The phone's side: send a copy of this account to the computer behind
  /// [payload], and return once the computer says it is restored.
  ///
  /// The computer is found first and the copy made after. The other way
  /// round, a phone with a gallery spent minutes on a copy before learning
  /// the computer was on another network or behind its firewall — showing
  /// "sending" the whole time.
  Future<void> sendTo(
    DesktopLinkPayload payload, {
    void Function(LinkProgress progress)? onProgress,
  }) async {
    void report(LinkProgress p) => onProgress?.call(p);

    report(const LinkProgress(LinkStage.connecting));
    final probe = await _connectFirst(payload.candidates, payload.port);
    final host = probe.remoteAddress.address;
    probe.destroy();
    DebugLog.instance.log('LINK', 'found the computer at $host');

    final archive = await _tempFile('link-send');
    try {
      report(const LinkProgress(LinkStage.preparing));
      final started = DateTime.now();
      await _createBackup(archive, payload.password);
      final size = await archive.length();
      DebugLog.instance.log(
        'LINK',
        'copy of $size bytes made in '
            '${DateTime.now().difference(started).inSeconds} s',
      );
      if (size <= 0 || size > PhoneTransferService.maxTransferBytes) {
        throw const FormatException('transfer is too large or empty');
      }
      final socket = await Socket.connect(
        host,
        payload.port,
        timeout: const Duration(seconds: 12),
      );
      try {
        final length = ByteData(8)..setUint64(0, size);
        socket
          ..add(ascii.encode(payload.token))
          ..add(length.buffer.asUint8List());
        report(const LinkProgress(LinkStage.transferring));
        var sent = 0;
        var shownPercent = 0;
        // Counted as it is read: addStream reads no faster than the socket
        // drains, so this follows the network closely enough to show.
        await socket.addStream(
          archive.openRead().map((chunk) {
            sent += chunk.length;
            final percent = sent * 100 ~/ size;
            if (percent != shownPercent) {
              shownPercent = percent;
              report(LinkProgress(LinkStage.transferring, sent / size));
            }
            return chunk;
          }),
        );
        await socket.flush();
        DebugLog.instance.log('LINK', 'copy sent, waiting for the computer');
        report(const LinkProgress(LinkStage.restoring));
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

  /// Dials every address at once and keeps the first that answers.
  ///
  /// One after another would cost the full timeout for each address that is
  /// not on this Wi-Fi — an unroutable one simply never answers — before the
  /// right one is even tried.
  static Future<Socket> _connectFirst(List<String> hosts, int port) async {
    const timeout = Duration(seconds: 12);
    final tasks = <ConnectionTask<Socket>>[];
    final winner = Completer<Socket>();
    Object? lastError;
    var pending = hosts.length;
    for (final host in hosts) {
      final ConnectionTask<Socket> task;
      try {
        task = await Socket.startConnect(host, port);
      } catch (e) {
        lastError = e;
        pending--;
        continue;
      }
      tasks.add(task);
      unawaited(
        task.socket.then(
          (socket) {
            if (winner.isCompleted) {
              socket.destroy();
            } else {
              tasks.remove(task);
              winner.complete(socket);
            }
          },
          onError: (Object e) {
            lastError = e;
            if (--pending == 0 && !winner.isCompleted) {
              winner.completeError(e);
            }
          },
        ),
      );
    }
    if (pending == 0 && !winner.isCompleted) {
      winner.completeError(lastError ?? StateError('no address to connect'));
    }
    final timer = Timer(timeout, () {
      if (!winner.isCompleted) {
        winner.completeError(
          lastError ??
              const SocketException('The computer did not answer in time'),
        );
      }
    });
    try {
      return await winner.future;
    } finally {
      timer.cancel();
      // The losers: a connect still in flight is abandoned, and one that
      // lands later is destroyed by its own callback above.
      for (final task in tasks) {
        task.cancel();
      }
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
