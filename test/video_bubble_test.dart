import 'dart:io';

import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/video_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which messages become a player and which stay a document row.
///
/// The interesting part is not the happy case — it is everything that must
/// *not* match. A clip is carried by the file transport, so the classifier
/// runs over every file bubble in every chat, and a false positive is a
/// platform video decoder opened on a PDF.
Message _file({
  required String mime,
  String? path,
  MessageKind kind = MessageKind.file,
}) =>
    Message(
      id: 'm1',
      chatId: 'peer',
      text: mime,
      sentAt: DateTime(2026, 9, 8),
      isMine: false,
      kind: kind,
      filePath: path,
      fileName: 'clip.mp4',
      fileBytes: 1024,
    );

void main() {
  late Directory dir;
  late File clip;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cubechat_video_');
    clip = File('${dir.path}${Platform.pathSeparator}clip.mp4')
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a video file on disk plays here', () {
    expect(
      VideoBubble.handles(_file(mime: 'video/mp4', path: clip.path)),
      isTrue,
    );
  });

  test('the mime is matched by family, not by an exact string', () {
    expect(
      VideoBubble.handles(_file(mime: 'VIDEO/QuickTime', path: clip.path)),
      isTrue,
      reason: 'a sender may send any spelling of any container',
    );
  });

  test('a document is not a video, whatever it is called', () {
    expect(
      VideoBubble.handles(_file(mime: 'application/pdf', path: clip.path)),
      isFalse,
    );
  });

  test('a clip still in flight stays a file row', () {
    // The bytes have not landed, so there is nothing to open — and the file
    // bubble is the one that draws the transfer ring.
    expect(
      VideoBubble.handles(
        _file(mime: 'video/mp4', path: '${dir.path}/not-here.mp4'),
      ),
      isFalse,
    );
    expect(VideoBubble.handles(_file(mime: 'video/mp4')), isFalse);
  });

  test('only the file kind is considered', () {
    expect(
      VideoBubble.handles(
        _file(mime: 'video/mp4', path: clip.path, kind: MessageKind.text),
      ),
      isFalse,
    );
  });
}
