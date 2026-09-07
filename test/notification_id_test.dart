import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One banner per conversation on Android, one per message on iOS.
///
/// Reported as an iPhone showing a counter that did not match what arrived.
/// Every message in a chat was posted under `threadKey.hashCode`, and on iOS
/// re-using an identifier **replaces** the notification that had it — so five
/// stickers posted five requests and left one banner standing, showing the
/// last of them. Android was right all along: `MessagingStyle` carries the run
/// of messages inside that one banner and `number:` is the count beside it, so
/// a second id there would be a second copy of the same conversation.
///
/// Grouping on iOS was never what the shared id bought: `threadIdentifier`
/// already stacks a conversation together, and it stays.
/// Substring that stops at the end of the file rather than throwing.
String _slice(String s, int start, int len) =>
    s.substring(start, start + len > s.length ? s.length : start + len);

void main() {
  late final String source;

  setUpAll(() {
    source =
        File('lib/core/notifications/notification_service.dart').readAsStringSync();
  });

  test('the id depends on the platform', () {
    expect(
      source,
      contains('PlatformInfo.isIOS\n          ? _nextIosId(threadKey)'),
      reason: 'a single id per chat is right on Android and wrong on iOS',
    );
    expect(
      source,
      contains(': threadKey.hashCode & 0x7fffffff;'),
      reason: 'Android keeps the conversation id MessagingStyle needs',
    );
  });

  test('iOS ids do not repeat within a conversation', () {
    final start = source.indexOf('int _nextIosId(String threadKey)');
    expect(start, isNonNegative);
    final body = source.substring(start, start + 200);
    expect(
      body,
      contains('_iosIdSeq'),
      reason: 'without a step, every message lands on the same identifier and '
          'replaces the one before it, which is the whole bug',
    );
  });

  test('iOS ids stay inside what the platform channel carries', () {
    final start = source.indexOf('int _nextIosId(String threadKey)');
    final body = source.substring(start, start + 200);
    expect(body, contains('0x7fffffff'));
  });

  test('opening a chat takes down every banner it posted', () {
    // Cancelling only the conversation id would leave the per-message ones
    // standing on iOS — read the chat, and the notifications stay.
    expect(source, contains('final List<int> postedIds = []'));
    expect(source, contains('thread.notePosted(id);'));
    final start = source.indexOf('Future<void> clearForChat(');
    expect(start, isNonNegative);
    final body = _slice(source, start, 1400);
    expect(body, contains('for (final id in posted)'));
    expect(
      body,
      contains('_plugin.cancel(threadKey.hashCode & 0x7fffffff)'),
      reason: 'the conversation id is still what Android posted under, and '
          'what older iOS builds left behind',
    );
  });

  test('the posted-id list is bounded', () {
    final start = source.indexOf('void notePosted(');
    expect(start, isNonNegative);
    expect(
      _slice(source, start, 300),
      contains('removeRange'),
      reason: 'it must not grow with the length of the conversation',
    );
  });
}
