import 'dart:io';
import 'dart:typed_data';

import '../util/debug_log.dart';
import 'inner_payload.dart';

/// A file transfer being put back together on disk.
///
/// Images and voice notes are reassembled in memory ([ImageReassembler]), and
/// for a photo capped at a few hundred kilobytes that is the simplest thing
/// that works. A file is not: holding twenty-five megabytes of somebody else's
/// upload in RAM — times however many transfers a peer chooses to open at once
/// — is both a memory problem and a denial-of-service surface. So chunks go
/// straight to a scratch file and only the bookkeeping stays resident.
///
/// Chunks are written at `seq * stride`, where the stride is the size of any
/// non-final chunk. The sender slices a transfer with one chunk size decided
/// up front, so every chunk but the last is that size — an invariant this
/// class enforces rather than assumes, because the bytes come from the other
/// side. A chunk that breaks it kills the transfer instead of silently
/// landing at the wrong offset.
class _PendingFile {
  _PendingFile({
    required this.total,
    required this.file,
    required this.handle,
    required this.startedAt,
  });

  final int total;
  final File file;

  /// Held open for the life of the transfer. Reopening per chunk would mean
  /// picking a [FileMode], and the only writing modes that do not truncate are
  /// the append ones — where POSIX `O_APPEND` sends every write to the end of
  /// the file regardless of where the position was set, which is precisely
  /// wrong for chunks that arrive out of order.
  final RandomAccessFile handle;

  final DateTime startedAt;

  /// Size of a non-final chunk, learned from the first one that arrives.
  /// Null until then — the final chunk is short and says nothing about it.
  int? stride;

  /// Sequences already on disk, so a duplicate does not count twice.
  final Set<int> have = <int>{};

  /// Chunks that arrived before the stride was known. In practice this holds
  /// at most the final chunk, and only when it overtakes every other.
  final Map<int, Uint8List> waiting = <int, Uint8List>{};

  int bytesOnDisk = 0;

  bool get complete => have.length == total;
}

/// Thrown when a file is past what the current transport can carry.
///
/// Typed rather than a bare [StateError] because the answer the user needs is
/// different in each case: over the mesh they have to send something smaller,
/// but on the relay path the same file may well go through once they are in
/// Bluetooth range of the recipient — and that is worth saying rather than
/// making them guess.
class FileTooLarge implements Exception {
  const FileTooLarge({
    required this.size,
    required this.cap,
    required this.relayOnly,
  });

  final int size;
  final int cap;

  /// True when the ceiling that was hit is the internet fallback's, which is
  /// far lower than the mesh's.
  final bool relayOnly;

  @override
  String toString() => 'FileTooLarge($size > $cap, relayOnly: $relayOnly)';
}

/// Result of a completed transfer: where the bytes landed and how many there
/// are. The caller verifies the manifest's SHA-256 before showing it to
/// anyone — this class only guarantees that every sequence arrived once.
class AssembledFile {
  const AssembledFile({required this.file, required this.bytes});

  final File file;
  final int bytes;
}

class FileReassembler {
  FileReassembler({
    required this.workDir,
    this.staleAfter = const Duration(minutes: 10),
    this.maxPendingTransfers = 4,
    this.maxBytesPerTransfer = 25 * 1024 * 1024,
    this.maxBytesOnDisk = 60 * 1024 * 1024,
  });

  /// Scratch directory for partial transfers. Injected rather than resolved
  /// through path_provider so this is testable without a plugin.
  final Directory workDir;

  /// A transfer nobody has fed in this long is abandoned. Longer than the
  /// image window (two minutes): a large file over BLE legitimately takes
  /// minutes, and expiring it mid-flight would waste everything already sent.
  final Duration staleAfter;

  /// Concurrent transfers per reassembler. Low on purpose — a file is a
  /// deliberate act, and a peer opening five at once is not a use case, it is
  /// an attempt to fill the disk.
  final int maxPendingTransfers;

  final int maxBytesPerTransfer;

  /// Ceiling across every partial transfer together, so the caps above cannot
  /// be multiplied out by opening more of them.
  final int maxBytesOnDisk;

  final Map<String, _PendingFile> _pending = <String, _PendingFile>{};

  /// Transfers we dropped, and when. Without this a cap does not actually cap
  /// anything: discarding the entry frees the id, and the very next chunk of
  /// the same stream starts a fresh transfer that fills up and is dropped
  /// again, forever. Remembering the id makes the rest of that stream cheap to
  /// ignore.
  final Map<String, DateTime> _dropped = <String, DateTime>{};

  int get pendingCount => _pending.length;

  int get bytesBuffered =>
      _pending.values.fold<int>(0, (s, p) => s + p.bytesOnDisk);

  /// How much of [fileId] has arrived, 0..1, for a progress indicator.
  double progressOf(Uint8List fileId) {
    final p = _pending[_keyOf(fileId)];
    if (p == null) return 0;
    return p.have.length / p.total;
  }

  /// Feed one chunk. Returns the assembled file once the last piece lands,
  /// null while the transfer is still incomplete or was dropped.
  Future<AssembledFile?> ingest(FileChunk chunk) async {
    await _gc();
    final key = _keyOf(chunk.fileId);
    if (_dropped.containsKey(key)) return null;
    var entry = _pending[key];

    if (entry == null) {
      if (_pending.length >= maxPendingTransfers) {
        DebugLog.instance.log('FILE', 'drop $key: pending transfer cap');
        return null;
      }
      if (!await workDir.exists()) {
        await workDir.create(recursive: true);
      }
      final f = File('${workDir.path}${Platform.pathSeparator}$key.part');
      entry = _PendingFile(
        total: chunk.total,
        file: f,
        // Truncating is right here and only here: the transfer is new, so
        // anything left under this id is debris from an abandoned one.
        handle: await f.open(mode: FileMode.write),
        startedAt: DateTime.now(),
      );
      _pending[key] = entry;
    }

    // total is fixed by the first chunk; a later one claiming a different
    // count is either a bug or an attempt to confuse the bookkeeping.
    if (chunk.total != entry.total) {
      DebugLog.instance.log('FILE', 'drop $key: total changed mid-transfer');
      await _discard(key);
      return null;
    }
    if (chunk.seq >= entry.total) {
      DebugLog.instance.log('FILE', 'drop $key: seq past total');
      await _discard(key);
      return null;
    }
    if (entry.have.contains(chunk.seq)) return null; // duplicate, ignore

    // A one-chunk transfer has no stride to learn — its only chunk is also the
    // final one, and it sits at offset zero. Without this the transfer would
    // park that chunk waiting for a stride that can never arrive.
    if (entry.total == 1) entry.stride = 0;

    final isFinal = chunk.seq == entry.total - 1;
    if (!isFinal) {
      final stride = entry.stride;
      if (stride == null) {
        entry.stride = chunk.data.length;
      } else if (chunk.data.length != stride) {
        DebugLog.instance.log('FILE', 'drop $key: ragged chunk size');
        await _discard(key);
        return null;
      }
    }

    // Refuse before writing, not after: the point of the cap is to not put the
    // bytes on disk in the first place.
    final projected = entry.bytesOnDisk + chunk.data.length;
    if (projected > maxBytesPerTransfer ||
        bytesBuffered + chunk.data.length > maxBytesOnDisk) {
      DebugLog.instance.log('FILE', 'drop $key: size cap');
      await _discard(key);
      return null;
    }

    final stride = entry.stride;
    if (stride == null) {
      // Only the final chunk so far, and its offset depends on a stride we
      // have not seen. Park it; it is one chunk.
      entry.waiting[chunk.seq] = chunk.data;
      entry.have.add(chunk.seq);
      entry.bytesOnDisk += chunk.data.length;
      return null;
    }

    await _writeAt(entry, chunk.seq, chunk.data, stride);
    entry.have.add(chunk.seq);
    entry.bytesOnDisk += chunk.data.length;

    if (entry.waiting.isNotEmpty) {
      for (final e in entry.waiting.entries) {
        await _writeAt(entry, e.key, e.value, stride);
      }
      entry.waiting.clear();
    }

    if (!entry.complete) return null;

    _pending.remove(key);
    await entry.handle.flush();
    await entry.handle.close();
    return AssembledFile(file: entry.file, bytes: entry.bytesOnDisk);
  }

  Future<void> _writeAt(
    _PendingFile entry,
    int seq,
    Uint8List data,
    int stride,
  ) async {
    await entry.handle.setPosition(seq * stride);
    await entry.handle.writeFrom(data);
  }

  /// Forget a transfer and remove its scratch file. [remember] marks the id so
  /// the rest of that stream is ignored rather than starting it over; a
  /// transfer that merely timed out is not remembered, so a peer coming back
  /// into range can retry.
  Future<void> _discard(String key, {bool remember = true}) async {
    if (remember) _dropped[key] = DateTime.now();
    final entry = _pending.remove(key);
    if (entry == null) return;
    try {
      await entry.handle.close();
    } catch (_) {/* already closed */}
    try {
      if (await entry.file.exists()) await entry.file.delete();
    } catch (e) {
      DebugLog.instance.log('FILE', 'could not remove $key: $e');
    }
  }

  Future<void> _gc() async {
    final now = DateTime.now();
    _dropped.removeWhere((_, at) => now.difference(at) > staleAfter);
    if (_pending.isEmpty) return;
    final dead = _pending.entries
        .where((e) => now.difference(e.value.startedAt) > staleAfter)
        .map((e) => e.key)
        .toList();
    for (final key in dead) {
      DebugLog.instance.log('FILE', 'expire $key: stalled');
      // Not remembered: a stall is usually the peer walking out of range, and
      // they should be able to start over when they come back.
      await _discard(key, remember: false);
    }
  }

  /// Drop everything in flight — used on logout / wipe, where leaving other
  /// people's half-transferred files on disk would be exactly wrong.
  Future<void> clear() async {
    for (final key in _pending.keys.toList()) {
      await _discard(key, remember: false);
    }
    _dropped.clear();
  }

  static String _keyOf(Uint8List id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
