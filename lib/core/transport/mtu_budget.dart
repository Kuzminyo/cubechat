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

/// Max total wire size (a full encoded [Frame]) for a single forward-secret
/// text frame on a link with the given [effectiveMtu]. A frame above this is
/// either sent SealedBox or, on very small MTUs, fragmented by the write layer
/// — either way it must not be handed to the radio whole.
int fsTextWireCeiling(int effectiveMtu) => effectiveMtu;
