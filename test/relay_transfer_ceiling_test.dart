import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/file_reassembly.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/transport/mtu_budget.dart';
import 'package:cubechat/core/transport/nostr/nostr_frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// What can be sent over the internet, and what decides it.
///
/// Three numbers have to agree: the chunk is one relay event, so it must fit
/// what a relay will accept; the ceiling is a chunk count, because every chunk
/// is a publish and publishes are what relays rate-limit; and the receiver has
/// to be willing to reassemble what the ceiling allows. Each was picked against
/// the others, and none of them says so in its own file.
void main() {
  /// Smallest `max_message_length` declared by the relays on the media lane,
  /// read from their NIP-11 documents on 2026-09-09:
  ///
  /// | relay | declared |
  /// |---|---|
  /// | relay.cubechat.tech | 131072 |
  /// | relay.snort.social | 524288 |
  /// | nostr.oxtr.dev | 131072 |
  ///
  /// The number this replaced was 64 KiB, which was strfry's *shipped default*
  /// rather than anything the lane actually enforces — ours sets 131072 in
  /// `relay/deploy/strfry.conf`. Believing the default cost a chunk size half
  /// what the relays would take, and therefore twice the publishes and twice
  /// the round trips on every transfer over the internet.
  ///
  /// Re-probe before changing `RelaySettings.defaultMediaUrls`. A relay added
  /// to that list with a smaller limit than this refuses every media chunk.
  const laneMessageLimit = 131072;

  test('a chunk fits in one relay event', () {
    // The message is `["EVENT",{…}]`: the content, plus the event's own JSON —
    // id, pubkey, sig, tags, kind, created_at and their punctuation, about 490
    // bytes. Taken generously, because being wrong in this direction only
    // makes the test stricter than reality.
    const eventJsonOverhead = 700;
    // The frame around the chunk: the inner-payload tag, the SealedBox/X3DH
    // sealing and the transport envelope.
    const wireOverhead = 512;
    final chunk = FileChunk(
      fileId: Uint8List(FileChunk.idLen),
      seq: 0,
      total: 1,
      data: Uint8List(kRelayMediaChunkData),
    );
    final inner = packInnerPayload(InnerPayloadType.fileChunk, chunk.encode());
    final content = NostrFrameCodec.encodeContent(
      Uint8List(inner.length + wireOverhead),
    );

    expect(
      content.length + eventJsonOverhead,
      lessThan(laneMessageLimit),
      reason: 'a refusal here is a transfer that cannot start rather than one '
          'that runs slowly, and it would be silent — the relay answers OK '
          'false and the chunk is simply gone',
    );
  });

  test('a chunk fits the wire format it is written into', () {
    // The chunk length rides in a u16, and a receiver accepts all of it —
    // see ImageChunk.maxDataBytes for why the receive limit is the field's
    // maximum rather than whatever the sender happens to use today.
    expect(ImageChunk.maxDataBytes, 65535);
    expect(AudioChunk.maxDataBytes, 65535);
    expect(FileChunk.maxDataBytes, 65535);
    // One size for all three: the relay path sizes them from the same budget.
    expect(ImageChunk.maxDataBytes, FileChunk.maxDataBytes);
    expect(AudioChunk.maxDataBytes, FileChunk.maxDataBytes);
  });

  test('what a sender sends leaves room under what a receiver accepts', () {
    // The slack is the point. A header field added later grows the frame, not
    // the chunk, but a sender pinned to the very top of the u16 would have no
    // room to absorb one — every chunk would throw on encode, which is a
    // transfer that fails rather than one that degrades.
    expect(kRelayMediaChunkData, lessThan(FileChunk.maxDataBytes));
    // 512 rather than a round kilobyte: the whole frame a chunk is wrapped in
    // — inner tag, sealing, envelope — is about 106 bytes, so this is several
    // times any header a later change could add.
    expect(FileChunk.maxDataBytes - kRelayMediaChunkData,
        greaterThanOrEqualTo(512));
  });

  test('the relay chunk is clamped by the type it is written into', () {
    expect(relayMediaChunkData(ceiling: FileChunk.maxDataBytes),
        kRelayMediaChunkData);
    // A hypothetically smaller chunk type wins over the target.
    expect(relayMediaChunkData(ceiling: 4096), 4096);
  });

  test('the BLE path is untouched by the relay chunk size', () {
    // The whole safety of the bigger chunk rests on this: it is reached only
    // when there is no Bluetooth link at all. Over BLE a chunk is still sized
    // for the fragmenter, and a 63 KiB one would be ~300 unpaced notifies.
    expect(bleMediaChunkData(225, ceiling: FileChunk.maxDataBytes),
        kBleMediaChunkData);
    expect(kBleMediaChunkData, lessThan(kRelayMediaChunkData));
  });

  test('the internet ceiling stays inside a sane publish budget', () {
    final publishes =
        (MessagingService.maxFileBytesRelay / kRelayMediaChunkData).ceil();

    expect(publishes, lessThanOrEqualTo(FileChunk.maxChunks),
        reason: 'the protocol caps the chunk count too');
    expect(
      publishes,
      lessThanOrEqualTo(2048),
      reason: 'every chunk is one publish and one round trip. This used to be '
          'a few hundred because a single rate-limited refusal threw the whole '
          'transfer away; delivery retries and paces into a relay that pushes '
          'back now, so the budget is what is polite to ask of somebody '
          "else's server rather than what survives one bad answer",
    );
    // The number people ask for, and why it is not an option. A relay is not a
    // file host: it prunes, it caps event size, and it throttles a burst. No
    // amount of patience on the sender makes thirty thousand publishes land.
    const oneGigabyte = 1024 * 1024 * 1024;
    expect(
      (oneGigabyte / kRelayMediaChunkData).ceil(),
      greaterThan(FileChunk.maxChunks),
      reason: 'a gigabyte does not even fit the chunk counter, let alone a '
          'relay — and it still does not at twice the chunk size',
    );
  });

  test('the mesh ceiling is exactly what the BLE chunking allows', () {
    // Not a matter of taste: a BLE media chunk is kBleMediaChunkData on any
    // link we can negotiate (the fragmenter decides it, not the MTU), and the
    // chunk count is capped. Past this, sendFile throws "too many chunks"
    // instead of sending — so the ceiling and the arithmetic have to agree, or
    // the app offers a size it cannot deliver.
    expect(
      MessagingService.maxFileBytesMesh,
      lessThanOrEqualTo(FileChunk.maxChunks * kBleMediaChunkData),
    );
  });

  test('the receiver will reassemble what the sender is allowed to send', () {
    // The directory is never touched — only the defaults are being read.
    final reassembler = FileReassembler(workDir: Directory.systemTemp);
    expect(
      MessagingService.maxFileBytesRelay,
      lessThanOrEqualTo(reassembler.maxBytesPerTransfer),
    );
    expect(
      MessagingService.maxFileBytesMesh,
      lessThanOrEqualTo(reassembler.maxBytesPerTransfer),
    );
  });
}
