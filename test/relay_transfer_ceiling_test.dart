import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/file_reassembly.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
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
  test('a chunk fits in one relay event', () {
    // Content goes out as `"cc1:" + base64(frame)`. The frame is the chunk plus
    // the inner-payload tag, the SealedBox/X3DH sealing and the envelope —
    // taken generously here, because being wrong in this direction only makes
    // the test stricter than reality.
    const wireOverhead = 512;
    final chunk = FileChunk(
      fileId: Uint8List(FileChunk.idLen),
      seq: 0,
      total: 1,
      data: Uint8List(FileChunk.maxDataBytes),
    );
    final inner = packInnerPayload(InnerPayloadType.fileChunk, chunk.encode());
    final content = NostrFrameCodec.encodeContent(
      Uint8List(inner.length + wireOverhead),
    );

    expect(
      content.length,
      lessThan(64 * 1024),
      reason: '64 KiB is where the common relay implementations refuse an '
          'event — strfry ships that as its default — and a refusal here is a '
          'transfer that cannot start rather than one that runs slowly',
    );
  });

  test('a chunk fits the wire format it is written into', () {
    // The chunk length rides in a u16.
    expect(ImageChunk.maxDataBytes, lessThanOrEqualTo(65535));
    expect(AudioChunk.maxDataBytes, lessThanOrEqualTo(65535));
    expect(FileChunk.maxDataBytes, lessThanOrEqualTo(65535));
    // One size for all three: the relay path sizes them from the same budget.
    expect(ImageChunk.maxDataBytes, FileChunk.maxDataBytes);
    expect(AudioChunk.maxDataBytes, FileChunk.maxDataBytes);
  });

  test('the internet ceiling stays inside a sane publish budget', () {
    final publishes =
        (MessagingService.maxFileBytesRelay / FileChunk.maxDataBytes).ceil();

    expect(publishes, lessThanOrEqualTo(FileChunk.maxChunks),
        reason: 'the protocol caps the chunk count too');
    expect(
      publishes,
      lessThanOrEqualTo(400),
      reason: 'every chunk is one publish and one round trip; past a few '
          'hundred the relays rate-limit, and that limit lands on ordinary '
          'messages too',
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
