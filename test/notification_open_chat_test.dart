import 'package:cubechat/app.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where a tapped notification should land you.
///
/// The bug: minimise the app while reading somebody, they write, tap the
/// notification — and the same conversation was pushed on top of itself. Back
/// popped one copy and left you in the chat you were trying to leave, which
/// reads as the button being broken.
void main() {
  const chat = '/chat/abc?name=Roma';
  const otherChat = '/chat/def?name=Kate';
  const channel = '/channel/team';

  group('already there', () {
    test('the same conversation does nothing at all', () {
      expect(
        notificationOpenAction(current: Uri.parse('/chat/abc'), target: chat),
        ChatOpenAction.alreadyThere,
      );
    });

    test('a renamed contact is still the same conversation', () {
      // The name rides in the query and is re-resolved from the roster on every
      // call. Comparing whole URIs would make a rename look like a different
      // destination and stack the chat on top of itself.
      expect(
        notificationOpenAction(
          current: Uri.parse('/chat/abc?name=Roma%20old'),
          target: chat,
        ),
        ChatOpenAction.alreadyThere,
      );
    });

    test('and so is the same channel', () {
      expect(
        notificationOpenAction(
          current: Uri.parse('/channel/team'),
          target: channel,
        ),
        ChatOpenAction.alreadyThere,
      );
    });
  });

  group('a different conversation replaces the one on screen', () {
    test('chat over chat', () {
      // Not a push: stacking would walk the reader back through everybody who
      // wrote while the app was in their pocket before reaching the list.
      expect(
        notificationOpenAction(
          current: Uri.parse('/chat/abc'),
          target: otherChat,
        ),
        ChatOpenAction.replace,
      );
    });

    test('channel over chat, and chat over channel', () {
      expect(
        notificationOpenAction(
          current: Uri.parse('/chat/abc'),
          target: channel,
        ),
        ChatOpenAction.replace,
      );
      expect(
        notificationOpenAction(
          current: Uri.parse('/channel/team'),
          target: chat,
        ),
        ChatOpenAction.replace,
      );
    });
  });

  group('anything else is pushed', () {
    test('from the chat list', () {
      expect(
        notificationOpenAction(current: Uri.parse('/chats'), target: chat),
        ChatOpenAction.push,
      );
    });

    test('from a settings screen', () {
      // Back from the chat should return here, so this one really is a push.
      expect(
        notificationOpenAction(current: Uri.parse('/storage'), target: chat),
        ChatOpenAction.push,
      );
    });

    test('a route that merely starts with the same letters is not a chat', () {
      expect(
        notificationOpenAction(current: Uri.parse('/chats'), target: channel),
        ChatOpenAction.push,
        reason: '/chats is the list, not a conversation',
      );
    });
  });
}
