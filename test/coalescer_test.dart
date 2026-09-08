import 'dart:async';

import 'package:cubechat/core/util/coalescer.dart';
import 'package:flutter_test/flutter_test.dart';

/// One job at a time per key, and one more if anybody asked during it.
///
/// 987 dropped the overlapping call instead, on the reasoning that "the one
/// already running will answer it with the newer state anyway". It does not: a
/// job reads shared state after it starts, so a request arriving mid-run
/// carries news it has gone past.
///
/// The report: four messages arrive inside two hundred milliseconds, the first
/// receipt sweep acknowledges the one it could see, the calls for the other
/// three are thrown away, and only re-opening the chat fixes it — the user
/// doing by hand what the re-run does here.
void main() {
  test('a lone call runs once', () async {
    final c = Coalescer();
    var runs = 0;
    await c.run('chat', () async => runs++);
    expect(runs, 1);
    expect(c.isRunning('chat'), isFalse);
  });

  test('three calls during a run produce exactly one repeat', () async {
    final c = Coalescer();
    final gate = Completer<void>();
    var runs = 0;

    final first = c.run('chat', () async {
      runs++;
      if (runs == 1) await gate.future;
    });

    // The three that 987 threw away.
    await c.run('chat', () async => runs++);
    await c.run('chat', () async => runs++);
    await c.run('chat', () async => runs++);
    expect(runs, 1, reason: 'they must not run beside the one in flight');
    expect(c.isPending('chat'), isTrue);

    gate.complete();
    await first;
    expect(runs, 2,
        reason: 'one re-run covers all three, because it reads the state '
            'fresh — the point is that it happens at all');
    expect(c.isPending('chat'), isFalse);
  });

  test('the repeat does not spin', () async {
    final c = Coalescer();
    var runs = 0;
    await c.run('chat', () async => runs++);
    await c.run('chat', () async => runs++);
    expect(runs, 2, reason: 'sequential calls are two runs, not a loop');
  });

  test('keys do not block each other', () async {
    final c = Coalescer();
    final gate = Completer<void>();
    var a = 0, b = 0;
    final first = c.run('a', () async {
      a++;
      await gate.future;
    });
    await c.run('b', () async => b++);
    expect(b, 1, reason: 'another chat is not waiting on this one');
    gate.complete();
    await first;
    expect(a, 1);
  });

  test('a stopped owner abandons the repeat', () async {
    final c = Coalescer();
    final gate = Completer<void>();
    var runs = 0;
    var dead = false;

    final first = c.run(
      'chat',
      () async {
        runs++;
        if (runs == 1) await gate.future;
      },
      stopped: () => dead,
    );
    await c.run('chat', () async => runs++);
    dead = true;
    gate.complete();
    await first;
    expect(runs, 1,
        reason: 'a torn-down service must not sweep against a dead world');
  });

  test('a throwing job still releases the key', () async {
    final c = Coalescer();
    await expectLater(
      c.run('chat', () async => throw StateError('boom')),
      throwsStateError,
    );
    expect(c.isRunning('chat'), isFalse,
        reason: 'otherwise one failure silences that chat for the session');
  });
}
