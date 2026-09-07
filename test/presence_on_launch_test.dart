import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A launch has to say we are here, and for a long time it did not.
///
/// Two logs from the same evening: one phone published a beacon to ten
/// contacts every seventy seconds; the other, booting twice inside ninety
/// seconds, sent not one in either session. So the first showed the second as
/// offline permanently — not intermittently, never. Reported as "не пишет даже
/// что в сети человек".
///
/// The cause was a flag whose own comment gave it away. `_announcedOnline`
/// started `true` "because the app is in the foreground when this observer is
/// installed" — which conflates where *we* are with what anyone has been
/// *told*. On a cold start the first is true and the second is not, and the
/// guard in `_announcePresenceDebounced` reads it as the second.
///
/// Source inspection rather than a widget test: reaching this needs the whole
/// app shell, a transport and a lifecycle observer, and what is being pinned is
/// a two-line invariant that a future edit could silently undo.
void main() {
  late final String source;

  setUpAll(() {
    source = File('lib/app.dart').readAsStringSync();
  });

  test('nothing is claimed to have been announced before it has been', () {
    expect(
      source,
      contains('bool _announcedOnline = false;'),
      reason: 'true here means a launch believes its contacts already know, '
          'and the debounce then refuses the only beacon it would have sent',
    );
  });

  test('a launch announces once, on its own', () {
    expect(source, contains('void _announceOnLaunch()'));
    // Called from the post-frame callback, which is the one place that runs on
    // every launch whether or not a lifecycle transition ever arrives.
    final start = source.indexOf('addPostFrameCallback');
    expect(start, isNonNegative);
    final callback = source.substring(start, start + 600);
    expect(
      callback,
      contains('_announceOnLaunch()'),
      reason: 'without this the first beacon of a launch waits on the '
          '70-second heartbeat, and a phone restarted more often than that '
          'never sends one at all',
    );
  });

  test('it goes to the service, not through the debounce', () {
    final start = source.indexOf('void _announceOnLaunch()');
    expect(start, isNonNegative);
    final body = source.substring(start, start + 400);
    expect(body, contains('announcePresence(online: true)'));
    expect(
      body,
      isNot(contains('_announcePresenceDebounced')),
      reason: 'the debounce is guarded by the very flag this exists to '
          'correct, so routing through it would restore the bug',
    );
  });

  test('it stays quiet when the launch is not into the foreground', () {
    final start = source.indexOf('void _announceOnLaunch()');
    final body = source.substring(start, start + 400);
    expect(
      body,
      contains('AppLifecycle.instance.isForeground'),
      reason: 'a background relaunch — a location wake, a push — is not '
          'somebody being in the app, and must not claim to be',
    );
  });
}
