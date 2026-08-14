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
}
