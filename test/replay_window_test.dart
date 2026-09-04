import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which payloads are allowed to arrive late.
///
/// The replay window is an hour, and it used to be the whole answer: past it,
/// dropped, whatever it was. A phone out of contact for longer therefore
/// received the mail waiting for it on the relay and destroyed it — seen in a
/// real log with two messages in it, 62 and 64 minutes old, gone with one
/// `drop signed body … stale` line and no gap in the conversation to notice.
///
/// The line drawn instead is the subject of this file, and it is worth pinning
/// because getting it wrong is silent in both directions: too generous and a
/// captured control frame can be replayed at leisure; too strict and mail is
/// destroyed again. Nothing about it produces a compile error or a crash.
void main() {
  group('what survives the replay window', () {
    test('a message and the media that travels with it', () {
      // These land in the message store, which dedupes by the sender's own id
      // and does so permanently — `skip already-stored message`. The window was
      // never their defence, so lifting it takes nothing away.
      for (final type in [
        InnerPayloadType.text,
        InnerPayloadType.textReply,
        InnerPayloadType.imageChunk,
        InnerPayloadType.audioChunk,
        InnerPayloadType.mediaManifest,
      ]) {
        expect(
          MessagingService.survivesReplayWindow(type),
          isTrue,
          reason: '${type.name} is mail and must not be destroyed by waiting',
        );
      }
    });

    test('nothing that changes a message already delivered', () {
      // An edit is the sharp one: replayed after the window, it would put back
      // a version the sender has since replaced. A delete, a reaction and a
      // receipt are milder but have the same shape — they act on something
      // already in the store, and the store cannot tell a late one from a
      // replayed one.
      for (final type in [
        InnerPayloadType.edit,
        InnerPayloadType.delete,
        InnerPayloadType.reaction,
        InnerPayloadType.receipt,
      ]) {
        expect(
          MessagingService.survivesReplayWindow(type),
          isFalse,
          reason: '${type.name} keeps the hard window',
        );
      }
    });

    test('nothing that changes a setting or a room', () {
      for (final type in [
        InnerPayloadType.presence,
        InnerPayloadType.copyRestriction,
        InnerPayloadType.forwardPrivacy,
        InnerPayloadType.conversationClear,
        InnerPayloadType.channelAdmin,
        InnerPayloadType.channelModeration,
        InnerPayloadType.channelInvite,
      ]) {
        expect(
          MessagingService.survivesReplayWindow(type),
          isFalse,
          reason: '${type.name} keeps the hard window',
        );
      }
    });

    test('the list is a decision, not a default', () {
      // A payload type added later inherits the strict window, which is the
      // safe direction: mail that is refused is reported, a control frame that
      // is accepted late is not.
      final survives = InnerPayloadType.values
          .where(MessagingService.survivesReplayWindow)
          .length;
      expect(survives, 5);
    });
  });
}
