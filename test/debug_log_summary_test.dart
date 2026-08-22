import 'package:cubechat/core/util/debug_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// The header that goes on top of a shared log.
///
/// It exists because of two round trips that kept repeating: a log shared to
/// answer "Bluetooth takes seven seconds" that came from the phone which only
/// ever accepted the connection, and a log that looked quiet because a storm
/// had already evicted everything else in it. Both are answerable from the
/// lines already in the buffer, and neither was being answered.
void main() {
  setUp(() {
    DebugLog.install();
    DebugLog.instance.clear();
  });

  tearDown(DebugLog.instance.clear);

  test('an empty buffer still says which build it came from', () {
    final summary = DebugLog.instance.summarize();
    expect(summary, contains('cubechat'));
    expect(summary, contains('log empty'));
  });

  test('a phone that only accepted connections is named as one', () {
    DebugLog.instance.log('BLE-PERIPH', 'central connected: aa:bb');
    DebugLog.instance.log('NOISE', 'handshake complete');

    final summary = DebugLog.instance.summarize();
    expect(summary, contains('only accepted connections'));
    // The point of the line: it says where to look next, not just what it saw.
    expect(summary, contains('the phone that dials'));
  });

  test('a phone that dialled out is named as one', () {
    DebugLog.instance.log('BLE-CENTRAL', 'connect -> aa:bb');

    expect(DebugLog.instance.summarize(), contains('only dialled out'));
  });

  test('a phone that did both says so', () {
    DebugLog.instance.log('BLE-CENTRAL', 'connect -> aa:bb');
    DebugLog.instance.log('BLE-PERIPH', 'central connected: cc:dd');

    expect(DebugLog.instance.summarize(), contains('both:'));
  });

  test('a window with no Bluetooth in it says that rather than guessing', () {
    DebugLog.instance.log('NOSTR', 'relay connected');

    expect(
      DebugLog.instance.summarize(),
      contains('no Bluetooth line in this window'),
    );
  });

  test('a full buffer says the window is already truncated', () {
    // Distinct lines, because an identical one is counted rather than appended
    // and would never fill the buffer.
    for (var i = 0; i < 210; i++) {
      DebugLog.instance.log('MESH', 'forwarded frame $i');
    }

    final summary = DebugLog.instance.summarize();
    expect(summary, contains('buffer full'));
    expect(summary, contains('already evicted'));
  });

  test('a buffer with room to spare does not claim to be truncated', () {
    DebugLog.instance.log('MESH', 'forwarded one frame');

    expect(DebugLog.instance.summarize(), isNot(contains('buffer full')));
  });

  test('the loudest tags are named, by repeat count and not by line count',
      () {
    // One line repeated is one entry with a count, which is exactly the shape
    // a storm takes in this buffer -- so counting entries would report the
    // storm as the quietest thing in the log.
    for (var i = 0; i < 50; i++) {
      DebugLog.instance.log('RECEIPT', 'no route for read acks');
    }
    DebugLog.instance.log('MESH', 'forwarded a frame');

    expect(DebugLog.instance.summarize(), contains('RECEIPT 50'));
  });
}
