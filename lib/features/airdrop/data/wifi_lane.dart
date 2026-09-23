import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/debug_log.dart';
import 'wifi_lane_codec.dart';

typedef WifiProgress = void Function(String mediaIdHex, int done, int total);

/// Asked when a file is whole on disk. True when AirDrop kept it.
typedef WifiKeep = Future<bool> Function(String mediaIdHex, File file);

/// Interfaces a phone never offers: cellular, VPN, tunnels. Names from
/// Android (`rmnet`, `ccmni`, `clat`), iOS (`pdp_ip`, `utun`, `ipsec`).
const _notLocal = [
  'rmnet',
  'ccmni',
  'pdp_ip',
  'clat',
  'v4-',
  'tun',
  'utun',
  'ipsec',
  'dummy',
  'lo',
];

InternetAddress? pickLanAddress(
  List<({String name, InternetAddress address})> candidates,
) {
  bool usable(({String name, InternetAddress address}) c) {
    final n = c.name.toLowerCase();
    if (_notLocal.any(n.startsWith)) return false;
    final a = c.address;
    if (a.isLoopback || a.isLinkLocal || a.isMulticast) return false;
    return true;
  }

  bool private4(InternetAddress a) {
    if (a.type != InternetAddressType.IPv4) return false;
    final b = a.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
        (b[0] == 192 && b[1] == 168);
  }

  final ok = candidates.where(usable).toList();
  for (final c in ok) {
    if (private4(c.address)) return c.address;
  }
  for (final c in ok) {
    if (c.address.type == InternetAddressType.IPv4) return c.address;
  }
  return ok.isEmpty ? null : ok.first.address;
}

/// Closes a [RandomAccessFile], swallowing the "already closed" case — the
/// one shape this ever needs, shared by both directions of the lane so a
/// violation and a close racing each other don't each need their own copy.
Future<void> _closeRaf(RandomAccessFile raf) async {
  try {
    await raf.close();
  } on FileSystemException {
    // Already closed.
  }
}

/// One file being written to disk by the receiver.
class _Incoming {
  _Incoming(this.file, this.raf, this.size);
  final File file;
  final RandomAccessFile raf;
  final int size;
  int received = 0;
  DateTime lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
}

/// Takes one connection that proves it holds [key] over [transferId], then
/// writes the files it names to `tempDir/wifi-<mediaIdHex>.part` until every
/// entry in [expected] has been kept or the connection is closed.
///
/// Only the first socket to prove itself is kept — every later connection is
/// destroyed on arrival, which is what keeps a second phone on the same LAN
/// from being able to inject anything even if it guesses the port.
class WifiLaneReceiver {
  WifiLaneReceiver._(
    this._server,
    this._port,
    this._key,
    this._transferId,
    this._tempDir,
    this._onProgress,
    this._onFile,
    this._idle,
  ) : _expected = {};

  static Future<WifiLaneReceiver> start({
    required InternetAddress address,
    required Uint8List key,
    required Uint8List transferId,
    required Map<String, int> expected,
    required Directory tempDir,
    required WifiProgress onProgress,
    required WifiKeep onFile,
    void Function()? onConnected,
    Duration idle = const Duration(minutes: 2),
  }) async {
    final server = await ServerSocket.bind(address, 0);
    final rx = WifiLaneReceiver._(
      server,
      server.port,
      Uint8List.fromList(key),
      Uint8List.fromList(transferId),
      tempDir,
      onProgress,
      onFile,
      idle,
    );
    rx._expected.addAll(expected);
    rx._onConnected = onConnected;
    rx._armIdle();
    rx._sub = server.listen(rx._onSocket);
    return rx;
  }

  final ServerSocket _server;

  /// Captured at bind time: `ServerSocket.port` throws once the socket is
  /// closed, and a caller is entitled to ask [port] after [close] (the idle
  /// test does, to prove the port really stopped accepting).
  final int _port;
  final Uint8List _key;
  final Uint8List _transferId;
  final Directory _tempDir;
  final WifiProgress _onProgress;
  final WifiKeep _onFile;
  final Duration _idle;
  final Map<String, int> _expected;
  final Map<String, _Incoming> _writing = {};

  void Function()? _onConnected;
  StreamSubscription<Socket>? _sub;
  Timer? _idleTimer;
  Socket? _proven;
  StreamSubscription<Uint8List>? _provenSub;
  WifiLaneCipher? _sealCipher;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;
  final Completer<void> _done = Completer<void>();

  /// True while a batch handler is running as the current `_queue` entry —
  /// so a `close()` called *from inside* that handler (a manifest violation,
  /// say) knows not to wait on `_queue` for itself. See [close].
  bool _insideQueue = false;

  /// Every socket accepted and not yet destroyed — not just the proven one.
  /// A decoy connection can still be mid-handshake when [close] runs (the
  /// idle timer firing while a second phone is dialling in), and it must not
  /// be left open just because it was never the winner.
  final Set<Socket> _liveSockets = {};

  int get port => _port;
  Future<void> get done => _done.future;

  void _armIdle() {
    _idleTimer?.cancel();
    if (_closed) return;
    _idleTimer = Timer(_idle, close);
  }

  void _destroy(Socket socket) {
    _liveSockets.remove(socket);
    socket.destroy();
  }

  void _onSocket(Socket socket) {
    if (_proven != null) {
      socket.destroy();
      return;
    }
    _liveSockets.add(socket);
    final openCipher = WifiLaneCipher(_key, WifiDirection.toReceiver);
    final sealCipher = WifiLaneCipher(_key, WifiDirection.toSender);
    final framer = WifiRecordFramer();
    var provedThisSocket = false;

    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        if (_closed) return;
        // Only the socket that has already proven itself can keep this
        // receiver alive — an unauthenticated connection resetting the idle
        // clock would let anyone on the LAN hold the port open forever just
        // by sending noise at it.
        if (socket == _proven) _armIdle();
        framer.add(chunk);
        List<Uint8List> sealed;
        try {
          sealed = framer.take();
        } on FormatException {
          DebugLog.instance.log('AIRDROP', 'wifi: refused a connection');
          _destroy(socket);
          sub.cancel();
          return;
        }
        if (sealed.isEmpty) return;
        sub.pause();
        _queue = _queue.then((_) async {
          if (_closed) return;
          _insideQueue = true;
          try {
            List<WifiRecord> records;
            try {
              records = await openCipher.open(sealed);
            } on FormatException {
              DebugLog.instance.log('AIRDROP', 'wifi: refused a connection');
              // A corrupt record from the proven socket ends the whole
              // transfer right away rather than waiting for the idle timer
              // to notice nothing more will ever arrive on it.
              if (socket == _proven) {
                await close();
              } else {
                _destroy(socket);
              }
              return;
            }
            if (!provedThisSocket) {
              final first = records.isEmpty ? null : records.first;
              if (first == null ||
                  first.kind != WifiRecordKind.hello ||
                  !_bytesEqual(first.body, _transferId)) {
                DebugLog.instance.log('AIRDROP', 'wifi: refused a connection');
                _destroy(socket);
                return;
              }
              if (_proven != null) {
                // Another socket proved itself first while this one was
                // being opened; only the first winner stays.
                _destroy(socket);
                return;
              }
              provedThisSocket = true;
              _proven = socket;
              _provenSub = sub;
              _sealCipher = sealCipher;
              _onConnected?.call();
              records = records.skip(1).toList();
            }
            await _handleRecords(socket, records);
          } catch (e) {
            // Anything else — a disk-full FileSystemException from
            // writeFrom/open, or a throwing onFile/onProgress/onConnected —
            // leaves this batch unable to finish cleanly. Uncaught, the
            // future this batch produces would carry the error forward and
            // nothing awaits `_queue` to ever see it — closing now is the
            // only response that leaves nothing half-done or silently stuck.
            DebugLog.instance.log('AIRDROP', 'wifi: receive failed, closing');
            if (socket == _proven) {
              await close();
            } else {
              _destroy(socket);
            }
          } finally {
            _insideQueue = false;
          }
        }).whenComplete(() {
          // Resume only after this batch has fully run (however it ended) —
          // that is the backpressure: a sender that races ahead just fills
          // the TCP receive buffer instead of racing the order records are
          // applied in. `whenComplete` (not `then`) guarantees this runs
          // even on a batch that somehow still throws past the catch above.
          if (!_closed) sub.resume();
        });
      },
      onDone: () {
        _liveSockets.remove(socket);
        // The proven socket hanging up means nothing more is ever coming;
        // waiting out the idle timer would just leave the port bound and
        // the caller guessing for up to two minutes.
        if (socket == _proven) close();
      },
      onError: (Object _, StackTrace __) {
        _liveSockets.remove(socket);
        if (socket == _proven) close();
      },
      cancelOnError: true,
    );
  }

  Future<void> _handleRecords(Socket socket, List<WifiRecord> records) async {
    for (final r in records) {
      if (_closed) return;
      switch (r.kind) {
        case WifiRecordKind.fileStart:
          await _onFileStart(socket, r.body);
        case WifiRecordKind.data:
          await _onData(socket, r.body);
        case WifiRecordKind.fileEnd:
          await _onFileEnd(socket, r.body);
        case WifiRecordKind.hello:
        case WifiRecordKind.fileKept:
        case WifiRecordKind.fileRefused:
          // Not sent by a sender; ignore rather than drop the connection.
          break;
      }
    }
  }

  String? _currentId;

  Future<void> _onFileStart(Socket socket, Uint8List body) async {
    if (body.length != 24) return;
    final mediaIdHex = nearbyHex(Uint8List.sublistView(body, 0, 16));
    final size = ByteData.sublistView(body, 16, 24).getUint64(0);
    final want = _expected[mediaIdHex];
    if (want == null || want != size) {
      // A size that disagrees with the offer is a manifest violation, not a
      // file this app happens not to want — refuse and end the connection
      // rather than keep trusting a sender that already lied once.
      await _refuseSend(socket, mediaIdHex);
      await close();
      return;
    }
    // A second fileStart for an id already open closes the earlier handle
    // first — otherwise that RandomAccessFile is orphaned, still open, and
    // its bytes on disk belong to nothing.
    final previous = _writing.remove(mediaIdHex);
    if (previous != null) {
      await _closeRaf(previous.raf);
      await _deletePart(previous.file);
    }
    if (_closed) return;
    final file = File('${_tempDir.path}/wifi-$mediaIdHex.part');
    final raf = await file.open(mode: FileMode.write);
    if (_closed) {
      // close() ran while the file was opening — nobody will ever sweep an
      // entry we're about to add, so clean up this one ourselves.
      await _closeRaf(raf);
      await _deletePart(file);
      return;
    }
    _writing[mediaIdHex] = _Incoming(file, raf, size);
    _currentId = mediaIdHex;
  }

  Future<void> _onData(Socket socket, Uint8List body) async {
    final id = _currentId;
    if (id == null) return;
    final w = _writing[id];
    if (w == null) return;
    if (w.received + body.length > w.size) {
      // Stop writing this file right away — an over-long stream is either a
      // bug on the other end or an attempt to fill this phone's disk, and
      // the handle must not stay open past the refusal.
      _writing.remove(id);
      _currentId = null;
      await _closeRaf(w.raf);
      await _deletePart(w.file);
      await _refuseSend(socket, id);
      await close();
      return;
    }
    await w.raf.writeFrom(body);
    if (_closed) return;
    w.received += body.length;
    final now = DateTime.now();
    if (now.difference(w.lastProgress) >= const Duration(milliseconds: 250) ||
        w.received == w.size) {
      w.lastProgress = now;
      _onProgress(id, w.received, w.size);
    }
  }

  Future<void> _onFileEnd(Socket socket, Uint8List body) async {
    final id = _currentId;
    if (id == null) return;
    // Left in `_writing` until the very end of whichever branch below
    // resolves it: if something throws partway through (onFile, a control
    // send), `close()`'s sweep of `_writing` still finds and cleans it up,
    // rather than it being lost the moment it was removed here.
    final w = _writing[id];
    _currentId = null;
    if (w == null) return;
    await _closeRaf(w.raf);
    if (_closed) return;
    if (w.received != w.size) {
      await _refuseSend(socket, id);
      await _deletePart(w.file);
      _writing.remove(id);
      await _resolved(id);
      return;
    }
    // Never hand a file to the app once shutting down — the caller that
    // asked for it may already have moved on.
    if (_closed) return;
    final kept = await _onFile(id, w.file);
    if (!kept) {
      await _refuseSend(socket, id);
      await _deletePart(w.file);
      _writing.remove(id);
      await _resolved(id);
      return;
    }
    await _sendControl(socket, WifiRecordKind.fileKept, nearbyUnhex(id));
    _writing.remove(id);
    await _resolved(id);
  }

  /// This id will never arrive again on this one-shot connection, whether it
  /// was kept or refused — drop it from what we're still waiting on, and end
  /// the transfer once nothing is left.
  Future<void> _resolved(String mediaIdHex) async {
    _expected.remove(mediaIdHex);
    if (_expected.isEmpty) {
      _completeDone();
      await close();
    }
  }

  Future<void> _refuseSend(Socket socket, String mediaIdHex) async {
    try {
      await _sendControl(socket, WifiRecordKind.fileRefused, nearbyUnhex(mediaIdHex));
    } on SocketException {
      // Already gone; nothing more to tell it.
    }
  }

  Future<void> _sendControl(Socket socket, WifiRecordKind kind, Uint8List body) async {
    final seal = _sealCipher;
    if (seal == null) return;
    final sealed = await seal.seal([WifiRecord(kind, body)]);
    for (final s in sealed) {
      socket.add(WifiLaneCodec.frame(s));
    }
    try {
      await socket.flush();
    } on SocketException {
      // Peer already gone.
    }
  }

  Future<void> _deletePart(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort — a close race can beat us to it.
    }
  }

  void _completeDone() {
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    await _sub?.cancel();
    await _provenSub?.cancel();
    for (final s in _liveSockets.toList()) {
      s.destroy();
    }
    _liveSockets.clear();
    try {
      await _server.close();
    } on SocketException {
      // Already down.
    }
    // A call from *inside* a queued handler (a manifest violation refusing
    // and closing) is itself the in-flight batch — awaiting `_queue` here
    // would wait on itself and never return. A call from outside that chain
    // (the idle timer, or a caller ending the transfer) is not part of it,
    // so it waits for whatever batch is currently running to reach its next
    // checkpoint (or finish) first. That's what keeps this from closing a
    // RandomAccessFile that a batch still has an `await writeFrom` pending
    // against — the two can no longer land at the same moment.
    if (!_insideQueue) {
      await _queue;
    }
    final writing = _writing.values.toList();
    _writing.clear();
    for (final w in writing) {
      await _closeRaf(w.raf);
      await _deletePart(w.file);
    }
    _completeDone();
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One connection to a [WifiLaneReceiver], proven with [transferId] and used
/// to push files one at a time.
class WifiLaneSender {
  WifiLaneSender._(this._socket, this._openCipher, this._sealCipher) {
    _framer = WifiRecordFramer();
    _sub = _socket.listen(
      _onData,
      onDone: _failAll,
      onError: (Object _, StackTrace __) => _failAll(),
      cancelOnError: true,
    );
  }

  static Future<WifiLaneSender?> connect({
    required NearbyWifiEndpoint endpoint,
    required Uint8List transferId,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        endpoint.address,
        endpoint.port,
        timeout: timeout,
      );
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on SocketException {
      socket.destroy();
      return null;
    }
    final openCipher = WifiLaneCipher(endpoint.key, WifiDirection.toSender);
    final sealCipher = WifiLaneCipher(endpoint.key, WifiDirection.toReceiver);
    final sender = WifiLaneSender._(socket, openCipher, sealCipher);
    try {
      final sealed = await sealCipher.seal([
        WifiRecord(WifiRecordKind.hello, Uint8List.fromList(transferId)),
      ]);
      for (final s in sealed) {
        socket.add(WifiLaneCodec.frame(s));
      }
      await socket.flush();
    } on SocketException {
      await sender.close();
      return null;
    }
    return sender;
  }

  final Socket _socket;
  final WifiLaneCipher _openCipher;
  final WifiLaneCipher _sealCipher;
  late final WifiRecordFramer _framer;
  late final StreamSubscription<Uint8List> _sub;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  /// Set once the connection is known broken — a stream error, a hang-up, or
  /// a record that failed to open. A later `sendFile` call fails fast on it
  /// instead of writing into a socket that will only ever error back out.
  bool _dead = false;

  final Map<String, Completer<bool>> _pending = {};

  void _onData(Uint8List chunk) {
    _framer.add(chunk);
    List<Uint8List> sealed;
    try {
      sealed = _framer.take();
    } on FormatException {
      _socket.destroy();
      _failAll();
      return;
    }
    if (sealed.isEmpty) return;
    _queue = _queue.then((_) async {
      if (_closed) return;
      List<WifiRecord> records;
      try {
        records = await _openCipher.open(sealed);
      } on FormatException {
        _socket.destroy();
        _failAll();
        return;
      }
      for (final r in records) {
        switch (r.kind) {
          case WifiRecordKind.fileKept:
            _resolve(r.body, true);
          case WifiRecordKind.fileRefused:
            _resolve(r.body, false);
          case WifiRecordKind.hello:
          case WifiRecordKind.fileStart:
          case WifiRecordKind.data:
          case WifiRecordKind.fileEnd:
            break;
        }
      }
    });
  }

  void _resolve(Uint8List mediaId, bool ok) {
    if (mediaId.length != 16) return;
    final id = nearbyHex(mediaId);
    final c = _pending.remove(id);
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void _failAll() {
    _dead = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _pending.clear();
  }

  /// True when the receiver answered [WifiRecordKind.fileKept] for it.
  Future<bool> sendFile({
    required String mediaIdHex,
    required File file,
    required int size,
    required WifiProgress onProgress,
    required bool Function() cancelled,
  }) async {
    if (_closed || _dead) return false;
    final completer = Completer<bool>();
    _pending[mediaIdHex] = completer;
    RandomAccessFile? raf;
    try {
      final startBody = Uint8List(24)
        ..setRange(0, 16, nearbyUnhex(mediaIdHex));
      ByteData.sublistView(startBody).setUint64(16, size);
      await _sendControl(WifiRecordKind.fileStart, startBody);
      raf = await file.open();
      var sent = 0;
      while (sent < size) {
        if (cancelled()) {
          _pending.remove(mediaIdHex);
          await close();
          return false;
        }
        // Capped at what's left to send: the file on disk may be larger
        // than the size promised in fileStart (it changed after the offer,
        // or the caller passed the wrong number), and reading past `size`
        // would send more than the receiver was told to expect, which it
        // then refuses.
        final remaining = size - sent;
        final toRead = remaining < (1 << 20) ? remaining : (1 << 20);
        final chunk = await raf.read(toRead);
        if (chunk.isEmpty) break;
        final records = <WifiRecord>[];
        for (var at = 0; at < chunk.length; at += WifiLaneCodec.dataBytes) {
          final end = (at + WifiLaneCodec.dataBytes < chunk.length)
              ? at + WifiLaneCodec.dataBytes
              : chunk.length;
          records.add(
            WifiRecord(WifiRecordKind.data, Uint8List.sublistView(chunk, at, end)),
          );
        }
        final sealed = await _sealCipher.seal(records);
        for (final s in sealed) {
          _socket.add(WifiLaneCodec.frame(s));
        }
        await _socket.flush();
        sent += chunk.length;
        onProgress(mediaIdHex, sent, size);
      }
      await _sendControl(WifiRecordKind.fileEnd, Uint8List(0));
    } on SocketException {
      _pending.remove(mediaIdHex);
      return false;
    } on FileSystemException {
      // The controller falls back to Bluetooth on false — this must never
      // throw past sendFile, even when the source file can't be opened or
      // read (permissions, it moved, the disk went away mid-send).
      _pending.remove(mediaIdHex);
      return false;
    } finally {
      final r = raf;
      if (r != null) await _closeRaf(r);
    }
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => false,
    );
  }

  Future<void> _sendControl(WifiRecordKind kind, Uint8List body) async {
    final sealed = await _sealCipher.seal([WifiRecord(kind, body)]);
    for (final s in sealed) {
      _socket.add(WifiLaneCodec.frame(s));
    }
    await _socket.flush();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAll();
    await _sub.cancel();
    _socket.destroy();
  }
}

/// What the controller uses to reach the network — a fake in tests.
abstract interface class AirDropWifi {
  Future<InternetAddress?> localAddress();

  Future<WifiLaneReceiver> startReceiver({
    required InternetAddress address,
    required Uint8List key,
    required Uint8List transferId,
    required Map<String, int> expected,
    required Directory tempDir,
    required WifiProgress onProgress,
    required WifiKeep onFile,
    void Function()? onConnected,
    Duration idle = const Duration(minutes: 2),
  });

  Future<WifiLaneSender?> connect({
    required NearbyWifiEndpoint endpoint,
    required Uint8List transferId,
  });
}

class IoAirDropWifi implements AirDropWifi {
  const IoAirDropWifi();

  @override
  Future<InternetAddress?> localAddress() async {
    try {
      final list = await NetworkInterface.list(includeLinkLocal: false);
      return pickLanAddress([
        for (final i in list)
          for (final a in i.addresses) (name: i.name, address: a),
      ]);
    } on SocketException {
      return null;
    }
  }

  @override
  Future<WifiLaneReceiver> startReceiver({
    required InternetAddress address,
    required Uint8List key,
    required Uint8List transferId,
    required Map<String, int> expected,
    required Directory tempDir,
    required WifiProgress onProgress,
    required WifiKeep onFile,
    void Function()? onConnected,
    Duration idle = const Duration(minutes: 2),
  }) {
    return WifiLaneReceiver.start(
      address: address,
      key: key,
      transferId: transferId,
      expected: expected,
      tempDir: tempDir,
      onProgress: onProgress,
      onFile: onFile,
      onConnected: onConnected,
      idle: idle,
    );
  }

  @override
  Future<WifiLaneSender?> connect({
    required NearbyWifiEndpoint endpoint,
    required Uint8List transferId,
  }) {
    return WifiLaneSender.connect(endpoint: endpoint, transferId: transferId);
  }
}

final airdropWifiProvider = Provider<AirDropWifi>((_) => const IoAirDropWifi());
