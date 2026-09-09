// Who a message is from has to be provable, not merely stated.
//
// A SealedBox is anonymous: anybody holding the recipient's public key — which
// is public, that is the point of it — can seal a body to them. The envelope
// around it carries an origin field saying who sent it, and that field is
// plaintext the sender wrote. So a body with no signature has no author, and
// accepting one meant a stranger with two public keys and a relay could put
// text into somebody else's conversation under their name.
//
// Not only text. `conversationClear` is a control message that erases the
// conversation it lands in, and it took the same path.
//
// The rule that closes it is small enough to state as a table, which is what
// this is. Two payloads are allowed through unsigned because a signature per
// chunk does not fit in the MTU, and they are held up instead by the manifest
// that opens the transfer — that one is signed.
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool accepted(InnerPayloadType type, {required bool fromTheLinkItself}) =>
      MessagingService.unsignedIsAcceptable(
        type: type,
        fromTheLinkItself: fromTheLinkItself,
      );

  group('over a relay, where there is no link to vouch for anybody', () {
    test('unsigned text is refused', () {
      expect(accepted(InnerPayloadType.text, fromTheLinkItself: false), isFalse);
    });

    test('the three chunk types are allowed through, files included', () {
      // fileChunk was the one missing from this list, and it cost every file
      // sent over the internet — a circle among them, since a circle travels
      // as a file. A shipped log has a 74-chunk transfer arrive and all 74 be
      // dropped here, with nothing on the sending side to say so.
      for (final type in const [
        InnerPayloadType.imageChunk,
        InnerPayloadType.audioChunk,
        InnerPayloadType.fileChunk,
      ]) {
        expect(
          accepted(type, fromTheLinkItself: false),
          isTrue,
          reason: '${type.name} is held up by the signed manifest that opens '
              'the transfer and by the digest it commits to, not by a '
              'signature of its own',
        );
      }
    });

    test('an unsigned request to erase the conversation is refused', () {
      expect(
        accepted(
          InnerPayloadType.conversationClear,
          fromTheLinkItself: false,
        ),
        isFalse,
        reason: 'this one deletes history, so it is the worst thing to take '
            'on the word of a field the sender filled in',
      );
    });

    test('every other payload is refused too, not just the ones named here',
        () {
      // Written as "all except" on purpose: a payload added later is refused
      // by default, and whoever adds one that must travel unsigned has to come
      // here and say so.
      const allowed = {
        InnerPayloadType.imageChunk,
        InnerPayloadType.audioChunk,
        InnerPayloadType.fileChunk,
      };
      for (final type in InnerPayloadType.values) {
        if (allowed.contains(type)) continue;
        expect(
          accepted(type, fromTheLinkItself: false),
          isFalse,
          reason: '${type.name} was accepted unsigned from a relay',
        );
      }
    });
  });

  group('media chunks, which cannot carry a signature', () {
    test('an image chunk is allowed either way', () {
      expect(accepted(InnerPayloadType.imageChunk, fromTheLinkItself: false),
          isTrue);
      expect(accepted(InnerPayloadType.imageChunk, fromTheLinkItself: true),
          isTrue);
    });

    test('an audio chunk is allowed either way', () {
      expect(accepted(InnerPayloadType.audioChunk, fromTheLinkItself: false),
          isTrue);
    });

    test('the manifest that opens the transfer is not', () {
      // The exception is the chunks, not the transfer. A manifest names the
      // sender and the media id the chunks will arrive under, and it is signed.
      expect(
        accepted(InnerPayloadType.mediaManifest, fromTheLinkItself: false),
        isFalse,
      );
    });
  });

  group('over a Noise link from the peer the envelope names', () {
    test('unsigned text is allowed, because the handshake vouches for it', () {
      // An older build still sends some control frames unsigned, and on a
      // direct link there is something better than a signature: the peer at
      // the other end proved they hold the key to be there at all.
      expect(accepted(InnerPayloadType.text, fromTheLinkItself: true), isTrue);
    });

    test('so is a request to erase the conversation', () {
      expect(
        accepted(InnerPayloadType.conversationClear, fromTheLinkItself: true),
        isTrue,
      );
    });
  });
}
