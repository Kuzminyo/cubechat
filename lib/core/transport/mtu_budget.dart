/// Sizing helpers that keep BLE frames inside the link's *negotiated* ATT MTU.
///
/// The bug these fix (confirmed from field logs): frames were sized for a
/// ~244-byte effective MTU, but real iOS↔Android links negotiate far less
/// (~207 effective was observed). A frame above the link's usable payload is
/// silently truncated by the BLE stack, so the AEAD open then fails and the
/// message/chunk is lost. `BleGattClient.negotiatedMtu` already reports the
/// real value; these helpers turn it into concrete data budgets.
///
/// Everything here is pure integer arithmetic so it is exhaustively unit-tested
/// without a device.
library;

import 'frame_fragment.dart' show kFragHeaderLen, kMaxFragments;

/// Every BLE notify/write value spends 3 bytes on the ATT header: the usable
/// application payload is `ATT_MTU - 3`.
const int kAttHeaderBytes = 3;

/// Slack shaved off the usable payload to absorb any off-by-a-few in our
/// overhead accounting and stacks that under-deliver near the ceiling. Cheap
/// insurance against the exact truncation this module exists to prevent.
const int kMtuSafetyMargin = 8;

/// Effective MTU to assume when the real negotiated value isn't known — a mesh
/// fan-out hop to links we don't track, or a peripheral-side notify before the
/// subscribed central's MTU has been reported up. 185 is the classic iPhone
/// default ATT_MTU; staying at/under it keeps frames deliverable across the
/// widest set of pairings.
const int kConservativeAttMtu = 185;

/// Non-`data` bytes in a single media-chunk transport frame, worst case (an
/// audio chunk under the SealedBox cipher):
///   frame type(1) + envelope header(33) + cipher tag(1) + SealedBox(48)
///   + inner-type(1) + audio-chunk header(27) + mime(≤10) ≈ 121, plus slack.
/// Image chunks are 4 B lighter (no duration field); budgeting for audio keeps
/// one constant safe for both.
const int kMediaChunkFrameOverhead = 124;

/// Floor on media-chunk `data` size, so a pathologically small MTU can't
/// explode a transfer into thousands of near-empty chunks.
const int kMinMediaChunkData = 40;

/// Target data bytes per media chunk on a BLE link, once the link-layer
/// fragmenter is doing the splitting.
///
/// Sizing a chunk to one BLE write is the obvious thing and it was badly wrong.
/// Each chunk pays [kMediaChunkFrameOverhead] — envelope, cipher tag, AEAD,
/// chunk header, mime — no matter how little it carries, so on a real iOS↔
/// Android link (225 B of usable payload) a chunk held 101 bytes of photo and
/// 124 bytes of packaging. A field log caught the result: **1367 chunks for one
/// photo**, 55% of the airtime spent on overhead, about two minutes on the
/// radio, and 1367 separate AEAD opens on the receiver.
///
/// Fragmentation removed the reason for the restriction. `frame_fragment.dart`
/// splits any oversized frame across writes and rejoins it before dispatch, so
/// a chunk no longer has to fit one write. At 4 KiB the same photo is 34 chunks
/// of ~19 fragments: per-chunk overhead falls from 55% to under 3%, roughly
/// halving both the bytes on air and the number of writes, with the 7-byte
/// fragment header the only thing replacing it.
const int kBleMediaChunkData = 4096;

/// Fragments one media chunk may occupy, well under the protocol's
/// [kMaxFragments].
///
/// The headroom is deliberate. A chunk that needs more than 255 fragments makes
/// `fragmentFrame` throw, which would fail the whole transfer — and the number
/// of fragments depends on a *negotiated* MTU that can come back far smaller
/// than anything seen in testing. Budgeting to a quarter of the cap means even
/// an absurd link degrades to smaller chunks instead of an exception.
const int kBleMaxFragmentsPerChunk = 64;

/// Target size for an outgoing photo, in bytes.
///
/// Media crosses the mesh in [mediaChunkDataBudget]-sized bites — 50 B on a
/// conservative 185-byte ATT MTU, 112 B on a negotiated 247 — paced at 15 ms a
/// chunk. Two things bound a photo: the 8192-chunk protocol cap (400 KB on the
/// *worst* link, not the best) and patience (400 KB there is ~2 minutes on the
/// radio). 192 KiB clears the cap on any link we can negotiate and holds the
/// send to roughly a minute at worst, ~25 s on a good link.
///
/// The camera's own JPEG is 10–20x this and even a 1280 px re-encode lands
/// around 1 MB, so the picker steps the resolution down until the bytes fit —
/// sizing by pixels alone is what let 10912-chunk images reach the transport
/// and throw.
const int kMaxOutgoingImageBytes = 192 * 1024;

/// Usable application payload for a link that negotiated [negotiatedMtu].
/// Never returns less than 20 (a link that small can't carry cubechat anyway,
/// but the caller shouldn't get a negative budget).
int effectivePayload(int negotiatedMtu) {
  final e = negotiatedMtu - kAttHeaderBytes - kMtuSafetyMargin;
  return e < 20 ? 20 : e;
}

/// Effective payload to use when the per-link MTU is unknown.
int conservativeEffectivePayload() => effectivePayload(kConservativeAttMtu);

/// Largest media-chunk `data` length whose full transport frame still fits an
/// [effectiveMtu]-byte payload, clamped to `[kMinMediaChunkData, ceiling]`.
/// [ceiling] is the chunk type's own protocol cap (e.g. `ImageChunk.maxDataBytes`).
int mediaChunkDataBudget(int effectiveMtu, {required int ceiling}) {
  final budget = effectiveMtu - kMediaChunkFrameOverhead;
  if (budget < kMinMediaChunkData) return kMinMediaChunkData;
  if (budget > ceiling) return ceiling;
  return budget;
}

/// Media-chunk `data` size for a BLE link with the given [effectiveMtu].
///
/// Aims at [kBleMediaChunkData] and steps down only when the link is so narrow
/// that the chunk would not fit [kBleMaxFragmentsPerChunk] slices. Never
/// returns less than [kMinMediaChunkData], and never a size that could make the
/// fragmenter throw.
int bleMediaChunkData(int effectiveMtu, {required int ceiling}) {
  final maxSlice = effectiveMtu - 1 - kFragHeaderLen;
  if (maxSlice < 1) return kMinMediaChunkData;
  final fits = maxSlice * kBleMaxFragmentsPerChunk - kMediaChunkFrameOverhead;
  if (fits < kMinMediaChunkData) return kMinMediaChunkData;
  final target = fits < kBleMediaChunkData ? fits : kBleMediaChunkData;
  return target > ceiling ? ceiling : target;
}

/// Max total wire size (a full encoded [Frame]) for a single forward-secret
/// text frame on a link with the given [effectiveMtu]. A frame above this is
/// either sent SealedBox or, on very small MTUs, fragmented by the write layer
/// — either way it must not be handed to the radio whole.
int fsTextWireCeiling(int effectiveMtu) => effectiveMtu;
