---
name: wire-protocol
description: The cubechat wire format and its compatibility rules. Load before touching lib/core/transport/** or lib/core/crypto/**, or when the task mentions a frame, envelope, payload type, tag byte, cipher tag, manifest version, peer id, handshake, Noise XX/IK, relay, store-and-forward, fragmentation, or channel crypto. Also load before adding any new kind of message, attachment, or shared object that has to travel between phones.
user-invocable: true
---

# cubechat wire protocol

Phones already in the field run older builds. A change here that compiles, passes
tests and looks right can still make two installed phones unable to talk. Nothing
in the toolchain catches that — this file is the check.

## The path of one message

```
BLE write / notify  ->  Frame              [type:1][payload:N]
                          |- transport     -> TransportEnvelope
                                              [originHash:8][destHash:8][msgId:16][ttl:1][body]
                                                body = [cipherTag:1][ciphertext]
                                                  ciphertext -> SignedPayload (Ed25519)
                                                                  -> InnerPayload [type:1][body]
```

`destHash` all-zero means broadcast (announcements, channels). Every relay
decrements `ttl`. Short text is padded to a 48-byte bucket so a passive sniffer
cannot read length. Frames larger than the link's negotiated MTU are split into
`fragment` frames and rejoined **before** dispatch, so dedup, replay and relay
never see a fragment.

## Four independent tag namespaces

They are separate numbering spaces and they overlap numerically. Check the right
one before assigning a byte.

| Namespace | Source of truth | Taken |
|---|---|---|
| `FrameType` | `lib/core/transport/frame.dart` | `noiseHandshake1..3` 0x01–0x03, `noiseIk1` 0x04, `noiseIk2` 0x05, `transport` 0x10, `peerAnnouncement` 0x20, `fragment` 0x40, `reset` 0xFE |
| envelope cipher tag | `messaging_service.dart`, the `_cipher*` constants | SealedBox 0x01, X3DH 0x02, channel 0x03, forward-secret media 0x04 |
| `InnerPayloadType` | `lib/core/transport/inner_payload.dart` | text 0x10, imageChunk 0x20, audioChunk 0x30, receipt 0x40, mediaManifest 0x50, reaction 0x60, channelInvite 0x70, edit 0x80, delete 0x90, and more below 0xFF — read the enum, do not trust this row |
| per-payload version byte | e.g. `MediaManifest.versionV1 .. versionV8ViewOnceCaptionFs` | one per field combination; `viewOnceVersionOffset` adds 0x04 |

Confirm with the file, not with this table:

```bash
grep -nE "0x[0-9A-Fa-f]{2}\)" lib/core/transport/inner_payload.dart | head -40
```

## Do not add an InnerPayloadType for a small payload

A few fields travel as a `cubechat:<kind>:v1:<base64url>` URI **inside an
ordinary text message**. That is the established pattern, and it is why an old
build shows a harmless unknown-payload line instead of dropping the message.

Existing kinds: `cubechat:loc:v1:` (`shared_location.dart`),
`cubechat:contact:v1:` (`shared_contact.dart`), `cubechat:sticker:v1`
(`Message.stickerMarker`), `cubechat:q1:channel:` (`qr/data/channel_qr_payload.dart`),
`cubechat:c1:` (`contact_card.dart`), `cubechat:t1:` (`phone_transfer_socket_service.dart`).

Adding a kind means teaching `lib/features/chat/domain/message_preview.dart`
about it too — that file is what stops a raw `cubechat:loc:v1:NTAuMDQx…` from
appearing in a chat row, a notification or a reply quote.

A new `InnerPayloadType` is for something genuinely new on the wire: a new
transfer mechanism, a new chunk stream, a new signed control message.

## Adding a payload type, in order

1. Pick an unused byte in the right namespace, verified against the enum.
2. Encode/decode with an explicit length check and a `FormatException` on bad
   input — every existing decoder does; a decoder that trusts its input is a
   remote crash.
3. Add a round-trip test plus a tampered-bytes test. `edit_delete_test.dart`
   and `channel_invite_test.dart` are the shape to copy.
4. Decide what an old build does when it receives it. Unknown inner types are
   dropped; if silently vanishing is wrong for this feature, it belongs in a
   text URI instead.
5. If it rides in a channel, it must survive arriving before the roster knows
   the sender — see `_replayHeldChannelState` / `_replayHeldChannelPosts` in
   `messaging_service.dart`.

## Rotating peer ids

```
id(pubkey, epoch) = BLAKE2s("cubechat/peer-id/v1" || pubkey || epoch_be64)[0:8]
epoch             = unix_millis ~/ 1h
```

Deterministic, so anyone holding the pubkey recomputes it with no negotiation —
but only stable for an hour. Receivers accept previous, current and next
(`PeerId.activeEpochs`), because a frame held in store-and-forward or sitting in
a relay backlog arrives bearing the epoch it was minted in.

**Never treat a peer id as a stable key.** Anything that indexes by it needs the
reverse index and its invalidation (`peer_id_test.dart` pins this). Store-and-
forward drains *all* of a peer's live ids — draining only the current one
strands exactly the mail that waited longest. The pre-rotation fixed hash is
still accepted on receive for staggered rollout; nothing mints it any more.

## Two handshakes

- **XX** — meeting a stranger. The responder's static key is in message 2:
  encrypted, but the initiator reads it, and the initiator is whoever just
  dialled you.
- **IK** (`noise_ik_handshake_state.dart`) — calling a peer whose key we already
  hold. The opener is encrypted under `es`, so producing one that decrypts *is*
  proof of holding the key. One round trip shorter; neither static key goes on
  the wire.

With **Profile → Discoverable nearby** off, XX is refused on sight and only IK is
answered — that is what makes id rotation more than theatre, since the cleartext
announcement would otherwise hand a listener the key every future id derives
from. Separate frame types rather than a flag, so a responder can refuse without
parsing.

## Hop budget

`TransportEnvelope.ttlForLinkCount`: full depth 7 at <=5 links, cut to 5 at 6+.
A flood costs roughly `fanout ^ hops`. Applied both when minting and at every
forward, using the density of whichever node relays. **It only ever lowers a
ttl** — a deliberately short budget (a relay introduction rides at 1) must never
be inflated.

## Media chunking

Chunks are sized for the fragmenter, not for one BLE write. Matching a chunk to
the MTU was measured at **1367 chunks for one photo** — over half the airtime was
envelope, AEAD and chunk header. At 4 KiB the same photo is ~34 chunks and
overhead drops under 3%. `bleMediaChunkData` steps the target down on narrow
links so a frame can never need more fragments than the 255 the header counts.
See `mtu_budget.dart` and `frame_fragment.dart`.
