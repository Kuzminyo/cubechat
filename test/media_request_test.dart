import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// Asking for a file again.
///
/// A received file lives on the receiver's disk and nowhere else, so clearing
/// it in the transfer centre left the bubble pointing at a path that no longer
/// existed. The only party who still has the bytes is the sender, and the answer
/// comes back under the *same* media id — which is what lets the old bubble
/// adopt it instead of a duplicate appearing underneath.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the request is a payload type of its own, and 16 bytes of id', () {
    final id = Uint8List.fromList(List.generate(16, (i) => i));
    final packed = packInnerPayload(InnerPayloadType.mediaRequest, id);
    final unpacked = unpackInnerPayload(packed);

    expect(unpacked.type, InnerPayloadType.mediaRequest);
    expect(unpacked.body, id);
    // Distinct from every other tag, or a request would be read as something
    // else entirely on the far side.
    final tags = InnerPayloadType.values.map((t) => t.tag).toList();
    expect(tags.toSet(), hasLength(tags.length));
  });

  group('adopting the re-sent file', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_refetch_');
      Hive.init(tempDir.path);
      container = ProviderContainer();
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows holds the Hive files briefly after close.
      }
    });

    Message file(String path) => Message(
          id: 'm1',
          chatId: 'ab',
          text: 'application/pdf',
          sentAt: DateTime(2026, 8, 4, 10),
          isMine: false,
          kind: MessageKind.file,
          filePath: path,
          fileName: 'договір.pdf',
          wireId: 'cd' * 16,
        );

    test('the bubble takes the new path without gaining a twin', () {
      final messages = container.read(messagesControllerProvider.notifier);
      messages.append('ab', file('/gone/договір.pdf'));

      // The re-send arrives with the same wireId, so append refuses it — that
      // rule is what stops a relay backlog replaying the whole history.
      expect(messages.append('ab', file('/inbox/договір.pdf')), isFalse);
      expect(
        messages.restoreFilePath('ab', 'cd' * 16, '/inbox/договір.pdf'),
        isTrue,
      );

      final stored = container.read(messagesControllerProvider)['ab']!;
      expect(stored, hasLength(1), reason: 'one file, one bubble');
      expect(stored.single.filePath, '/inbox/договір.pdf');
      expect(stored.single.fileName, 'договір.pdf', reason: 'nothing else moved');
    });

    test('a path for a message that is not there changes nothing', () {
      final messages = container.read(messagesControllerProvider.notifier);
      messages.append('ab', file('/inbox/договір.pdf'));

      expect(messages.restoreFilePath('ab', 'ee' * 16, '/x'), isFalse);
      expect(messages.restoreFilePath('zz', 'cd' * 16, '/x'), isFalse);
      expect(
        container.read(messagesControllerProvider)['ab']!.single.filePath,
        '/inbox/договір.pdf',
      );
    });
  });
}
