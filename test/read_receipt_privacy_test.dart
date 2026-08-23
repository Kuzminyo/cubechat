import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('read receipt privacy gate', () {
    late final String source;

    setUpAll(() {
      source =
          File('lib/core/transport/messaging_service.dart').readAsStringSync();
    });

    test('still ingests peer receipts when our read receipts are off', () {
      final call =
          RegExp(r'_ingestReceipt\(\s*peerId: peerId,').firstMatch(source);
      expect(call, isNotNull);

      final previousCase =
          source.lastIndexOf('case InnerPayloadType.receipt:', call!.start);
      expect(previousCase, isNonNegative);

      final receiptBranch = source.substring(previousCase, call.start);
      expect(receiptBranch, isNot(contains('shareReadReceipts')));
    });

    test('still ingests channel receipts when our read receipts are off', () {
      final call = RegExp(r'_ingestChannelReceipt\(\s*channel: channel,')
          .firstMatch(source);
      expect(call, isNotNull);

      final previousCase =
          source.lastIndexOf('case InnerPayloadType.receipt:', call!.start);
      expect(previousCase, isNonNegative);

      final receiptBranch = source.substring(previousCase, call.start);
      expect(receiptBranch, isNot(contains('shareReadReceipts')));
    });
  });

  group('the read marker', () {
    /// A receipt only ever reports what the marker says, so the marker is
    /// where honesty is decided — and it used to be advanced from `build`,
    /// which a chat left open behind a locked screen goes on running: every
    /// message that arrives changes the list the bar watches. A phone in a
    /// pocket marked each one read as it landed and the sender watched their
    /// ticks turn over for messages nobody had seen.
    ///
    /// Pinned by reading the source, the way the receipt gate above is: the
    /// alternative is pumping the whole chat screen with a transport under it.
    test('is not advanced while the app is not the one being looked at', () {
      final screen = File('lib/features/chat/presentation/chat_screen.dart')
          .readAsStringSync();
      final start = screen.indexOf('void _markChatRead()');
      expect(start, isNonNegative, reason: 'the method was renamed');

      final write = screen.indexOf('.markRead(', start);
      expect(write, isNonNegative);

      // Everything between entering the method and writing the marker. The
      // guard has to be in there, and being *before* the write is the point.
      expect(screen.substring(start, write), contains('isViewingChat'));
    });
  });
}
