// Who wakes up when a voice note or a circle is playing.
//
// Playback is one shared notifier, and every bubble on screen used to watch
// all of it. So one circle playing woke every other circle and every voice note
// in the conversation, many times a second, to redraw a bar that had not moved
// — which is what "the animations judder" was made of. These pin the two things
// that fixed it: the state compares by value, and each bubble selects only its
// own share of it.
import 'package:cubechat/features/chat/data/voice_playback_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two states with the same fields are equal', () {
    // Without this every copyWith was a fresh identity, so `select` could never
    // decide that nothing had changed and every listener woke on every tick.
    const a = VoicePlayback(
      messageId: 'm1',
      position: Duration(seconds: 3),
      duration: Duration(seconds: 10),
      playing: true,
    );
    const b = VoicePlayback(
      messageId: 'm1',
      position: Duration(seconds: 3),
      duration: Duration(seconds: 10),
      playing: true,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(b.copyWith(position: const Duration(seconds: 4))));
  });

  test('a bubble that is not playing sleeps through another one', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // What each bubble asks for: its own three numbers, or null when it is not
    // the current message. `null == null`, so the second bubble's selection is
    // unchanged by everything that happens to the first.
    ({bool playing, Duration position, Duration duration})? shareOf(
      VoicePlayback s,
      String id,
    ) =>
        s.isCurrent(id)
            ? (playing: s.playing, position: s.position, duration: s.duration)
            : null;

    var minesWoke = 0;
    var theirsWoke = 0;
    container.listen(
      voicePlaybackControllerProvider.select((s) => shareOf(s, 'mine')),
      (_, __) => minesWoke++,
    );
    container.listen(
      voicePlaybackControllerProvider.select((s) => shareOf(s, 'theirs')),
      (_, __) => theirsWoke++,
    );

    final notifier = container.read(voicePlaybackControllerProvider.notifier);
    notifier.state = const VoicePlayback(messageId: 'mine', playing: true);
    for (var i = 1; i <= 20; i++) {
      notifier.state = notifier.state.copyWith(
        position: Duration(milliseconds: i * 100),
      );
    }

    expect(minesWoke, greaterThan(1), reason: 'the one playing does redraw');
    expect(
      theirsWoke,
      0,
      reason: 'a bubble that is not the current message must not rebuild once '
          'for the whole of somebody else playing',
    );
  });

  test('a tick that changes nothing wakes nobody', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var woke = 0;
    container.listen(
      voicePlaybackControllerProvider.select((s) => s.position),
      (_, __) => woke++,
    );

    final notifier = container.read(voicePlaybackControllerProvider.notifier);
    const same = VoicePlayback(
      messageId: 'm1',
      position: Duration(seconds: 2),
      playing: true,
    );
    notifier.state = same;
    final before = woke;
    // The decoder reporting the same position again, which it does whenever a
    // frame lands inside the millisecond the last one did.
    notifier.state = same.copyWith();
    notifier.state = same.copyWith();
    expect(woke, before);
  });
}
