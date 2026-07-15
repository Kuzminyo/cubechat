import 'dart:math';
import 'dart:typed_data';

import 'frame.dart';

/// Link-layer fragmentation for frames that exceed a BLE link's usable MTU.
///
/// A frame larger than the negotiated payload is split into N fragment frames,
/// each laid out as
///
/// ```
///   [FrameType.fragment : 1][fragId : 4][index : 1][count : 1][slice : M]
/// ```
///
/// and reassembled on the far side *before* normal dispatch — so the mesh,
/// dedup, replay-window and relay logic never see fragments. The `slice` bytes
/// are a contiguous span of the ORIGINAL encoded frame (including its own type
/// byte), so concatenating the slices in index order reproduces it exactly.
///
/// This is what lets a forward-secret text (~215–230 B) or a media chunk reach
/// a peer across a low-MTU iOS↔Android link where a whole frame would be
/// truncated on the wire.

/// Header bytes after the frame-type byte: fragId(4) + index(1) + count(1).
const int kFragHeaderLen = 4 + 1 + 1;

/// Max fragments a single frame may split into — `index`/`count` are u8.
const int kMaxFragments = 255;

final _fragRand = Random.secure();

/// Split [frameBytes] (a fully-encoded [Frame]) into fragment frames whose
/// individual encoded size is `<= maxFrameBytes`. Returns a single-element list
/// holding [frameBytes] unchanged when it already fits — callers can send the
/// result verbatim in either case.
///
/// Throws [ArgumentError] if [maxFrameBytes] is too small to hold even a
/// one-byte slice, or if the frame would need more than [kMaxFragments]
/// fragments at this size (callers size media chunks so this never triggers in
/// practice; text frames are far too small to approach the cap).
List<Uint8List> fragmentFrame(Uint8List frameBytes, int maxFrameBytes) {
  if (frameBytes.length <= maxFrameBytes) return [frameBytes];

  final maxSlice = maxFrameBytes - 1 - kFragHeaderLen;
  if (maxSlice < 1) {
    throw ArgumentError('maxFrameBytes $maxFrameBytes too small to fragment');
  }
  final count = (frameBytes.length + maxSlice - 1) ~/ maxSlice;
  if (count > kMaxFragments) {
    throw ArgumentError(
        'frame of ${frameBytes.length}B needs $count fragments > $kMaxFragments '
        'at maxFrameBytes=$maxFrameBytes');
  }

  final fragId = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    fragId[i] = _fragRand.nextInt(256);
  }

  final out = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    final start = i * maxSlice;
    final end = start + maxSlice < frameBytes.length
        ? start + maxSlice
        : frameBytes.length;
    final sliceLen = end - start;
    final frag = Uint8List(1 + kFragHeaderLen + sliceLen);
    var c = 0;
    frag[c++] = FrameType.fragment.value;
    frag.setRange(c, c += 4, fragId);
    frag[c++] = i;
    frag[c++] = count;
    frag.setRange(c, c += sliceLen, frameBytes.sublist(start, end));
    out.add(frag);
  }
  return out;
}

/// Per-link reassembly buffer for [FrameType.fragment] frames.
///
/// Bounded in the same spirit as `ImageReassembler`: partial groups expire
/// after [staleAfter], and both the group count and total buffered bytes are
/// capped so a peer that streams fragments and never finishes can't grow memory
/// without limit.
class FrameFragmentReassembler {
  FrameFragmentReassembler({
    this.staleAfter = const Duration(seconds: 20),
    this.maxPendingGroups = 64,
    this.maxBufferedBytes = 512 * 1024,
  });

  final Duration staleAfter;
  final int maxPendingGroups;
  final int maxBufferedBytes;

  final Map<String, _PendingGroup> _pending = {};

  /// Feed the payload of one fragment frame — i.e. `Frame.decode(bytes).payload`
  /// for a frame whose type is [FrameType.fragment]. [linkKey] scopes the
  /// 4-byte fragId to one link so ids from different peers can't collide.
  ///
  /// Returns the fully-reassembled original frame bytes when the last missing
  /// fragment lands, otherwise null (more fragments still expected, or the
  /// fragment was malformed / a duplicate).
  Uint8List? ingest(String linkKey, Uint8List fragmentPayload) {
    _gc();
    if (fragmentPayload.length < kFragHeaderLen + 1) return null; // no slice

    final fragIdHex = _hex(fragmentPayload, 0, 4);
    final index = fragmentPayload[4];
    final count = fragmentPayload[5];
    if (count == 0 || index >= count) return null;
    final slice =
        Uint8List.sublistView(fragmentPayload, kFragHeaderLen);

    final key = '$linkKey:$fragIdHex';
    var group = _pending[key];
    if (group == null) {
      _evictUntilGroupSlot();
      group = _PendingGroup(count: count, startedAt: DateTime.now());
      _pending[key] = group;
    }
    if (group.count != count) {
      // count disagreement across fragments of the same id — corrupt; restart.
      _pending.remove(key);
      return null;
    }
    if (group.slices.containsKey(index)) return null; // duplicate

    group.slices[index] = slice;
    group.byteCount += slice.length;
    group.lastTouched = DateTime.now();
    if (_bufferedBytes > maxBufferedBytes) {
      _evictOldest(exceptKey: key);
    }

    if (group.slices.length != group.count) return null;

    final total = group.byteCount;
    final out = Uint8List(total);
    var cursor = 0;
    for (var i = 0; i < group.count; i++) {
      final s = group.slices[i]!;
      out.setRange(cursor, cursor += s.length, s);
    }
    _pending.remove(key);
    return out;
  }

  int get _bufferedBytes =>
      _pending.values.fold<int>(0, (s, g) => s + g.byteCount);

  void _gc() {
    final now = DateTime.now();
    _pending.removeWhere((_, g) => now.difference(g.startedAt) > staleAfter);
  }

  void _evictUntilGroupSlot() {
    while (_pending.length >= maxPendingGroups && _pending.isNotEmpty) {
      _evictOldest();
    }
  }

  void _evictOldest({String? exceptKey}) {
    String? oldestKey;
    DateTime? oldest;
    for (final e in _pending.entries) {
      if (e.key == exceptKey) continue;
      if (oldest == null || e.value.lastTouched.isBefore(oldest)) {
        oldest = e.value.lastTouched;
        oldestKey = e.key;
      }
    }
    if (oldestKey != null) _pending.remove(oldestKey);
  }

  static String _hex(Uint8List b, int start, int len) {
    final sb = StringBuffer();
    for (var i = start; i < start + len; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

class _PendingGroup {
  _PendingGroup({required this.count, required this.startedAt})
      : lastTouched = startedAt;

  final int count;
  final DateTime startedAt;
  DateTime lastTouched;
  int byteCount = 0;
  final Map<int, Uint8List> slices = {};
}
