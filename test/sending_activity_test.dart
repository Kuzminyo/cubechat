import 'package:cubechat/features/peers/data/peer_activity.dart';
import 'package:cubechat/features/peers/data/sending_activity.dart';
import 'package:cubechat/features/peers/data/typing_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Sending a photo…" stays up on the other phone for as long as a transfer
/// runs here, and comes down once — see [SendingActivity].
void main() {
  late List<String> said;
  late SendingActivity activity;

  void setUpActivity() {
    said = [];
    activity = SendingActivity(
      announce: (chat, kind) => said.add('$chat:${kind.name}'),
      stop: (chat) => said.add('$chat:stop'),
    );
  }

  test('said at once, repeated inside the receiver window, stopped after',
      () {
    fakeAsync((async) {
      setUpActivity();
      activity.begin('a', PeerActivity.sendingPhoto);
      expect(said, ['a:sendingPhoto']);

      // A two-minute photo over Bluetooth: never a gap the receiver's
      // eight-second window would lapse in.
      async.elapse(const Duration(minutes: 2));
      expect(activity.every, lessThan(TypingController.ttl));
      expect(said.length, 1 + 120 ~/ 5);
      expect(said.every((s) => s == 'a:sendingPhoto'), isTrue);

      said.clear();
      activity.end('a', PeerActivity.sendingPhoto);
      expect(said, isEmpty, reason: 'the stop lingers for the next photo');
      async.elapse(const Duration(seconds: 2));
      expect(said, ['a:stop']);

      async.elapse(const Duration(seconds: 30));
      expect(said, ['a:stop'], reason: 'nothing more once it is over');
      activity.dispose();
    });
  });

  test('an album does not blink between its photos', () {
    fakeAsync((async) {
      setUpActivity();
      for (var i = 0; i < 3; i++) {
        activity.begin('a', PeerActivity.sendingPhoto);
        async.elapse(const Duration(seconds: 3));
        activity.end('a', PeerActivity.sendingPhoto);
        async.elapse(const Duration(milliseconds: 300));
      }
      expect(said.where((s) => s == 'a:stop'), isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(said.last, 'a:stop');
      expect(said.where((s) => s == 'a:stop'), hasLength(1));
      activity.dispose();
    });
  });

  test('a clip outranks a photo, and the photo is said once the clip is done',
      () {
    fakeAsync((async) {
      setUpActivity();
      activity.begin('a', PeerActivity.sendingPhoto);
      activity.begin('a', PeerActivity.sendingVideo);
      expect(said.last, 'a:sendingVideo');

      activity.end('a', PeerActivity.sendingVideo);
      expect(said.last, 'a:sendingPhoto');
      async.elapse(const Duration(seconds: 5));
      expect(said.last, 'a:sendingPhoto');

      activity.end('a', PeerActivity.sendingPhoto);
      async.elapse(const Duration(seconds: 2));
      expect(said.last, 'a:stop');
      activity.dispose();
    });
  });

  test('two conversations are counted apart', () {
    fakeAsync((async) {
      setUpActivity();
      activity.begin('a', PeerActivity.sendingFile);
      activity.begin('b', PeerActivity.sendingVideo);
      activity.end('a', PeerActivity.sendingFile);
      async.elapse(const Duration(seconds: 6));
      expect(said, contains('a:stop'));
      expect(said.last, 'b:sendingVideo');
      expect(said.where((s) => s == 'b:stop'), isEmpty);
      activity.dispose();
    });
  });

  test('an end with no matching begin changes nothing', () {
    fakeAsync((async) {
      setUpActivity();
      activity.end('a', PeerActivity.sendingPhoto);
      async.elapse(const Duration(seconds: 5));
      expect(said, isEmpty);
    });
  });

  test('disposed, it says nothing more', () {
    fakeAsync((async) {
      setUpActivity();
      activity.begin('a', PeerActivity.sendingVideo);
      activity.dispose();
      said.clear();
      async.elapse(const Duration(minutes: 1));
      expect(said, isEmpty);
    });
  });
}
