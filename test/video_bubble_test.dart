import 'dart:io';

import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/video_bubble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cubechat/features/chat/domain/message_preview.dart';
import 'package:cubechat/features/chat/domain/message_search.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';

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
  String name = 'clip.mp4',
}) =>
    Message(
      id: 'm1',
      chatId: 'peer',
      text: mime,
      sentAt: DateTime(2026, 9, 8),
      isMine: false,
      kind: kind,
      filePath: path,
      fileName: name,
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

  test('circle belongs to voice notes without exposing the reserved filename',
      () {
    final circle =
        _file(mime: 'video/mp4', path: clip.path, name: Message.circleFileName);
    expect(circle.isVoiceNote, true);
    expect(circle.voiceNotePath, clip.path);
    expect(
        messageContentPreview(circle, AppLocalizationsEn()), '◉ Video message');
    expect(searchableMessageText(circle), isEmpty);
    expect(_file(mime: 'video/mp4', path: clip.path).isVoiceNote, false);
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

  group('a circle', () {
    // Circles travel as ordinary video files and are told apart by the name
    // they are sent under. A media kind of its own would read better on the
    // wire and receive worse: an older build throws on an unknown kind and
    // drops the transfer, where a reserved name lands as a video it can play.
    test('is recognised by the name it was sent under', () {
      final circle = _file(
        mime: 'video/mp4',
        path: clip.path,
        name: VideoBubble.circleFileName,
      );
      expect(VideoBubble.isCircle(circle), isTrue);
      expect(
        VideoBubble.handles(circle),
        isTrue,
        reason: 'it is still a video, and still plays in the bubble',
      );
    });

    test('an ordinary clip is not one', () {
      expect(
        VideoBubble.isCircle(_file(mime: 'video/mp4', path: clip.path)),
        isFalse,
      );
    });

    test('the marker carries a version, so a later shape is distinguishable',
        () {
      expect(VideoBubble.circleFileName, contains('v1'));
      expect(VideoBubble.circleFileName, endsWith('.mp4'),
          reason: 'an old build files it by extension and must still play it');
    });
  });

  group('how tall a clip is drawn', () {
    // A photo is capped at 1.25x its width and cropped past that. A clip was
    // capped at nothing: a 9:16 portrait out of a phone camera, at the
    // 300-point ceiling the width clamps to, came out 533 points tall — one
    // bubble filling a screen. Same rule for both now.
    test('a landscape clip keeps its own shape', () {
      expect(VideoBubble.rectangleHeight(300, 16 / 9), closeTo(168.75, 0.01));
    });

    test('a portrait clip stops where a portrait photo stops', () {
      expect(
        VideoBubble.rectangleHeight(300, 9 / 16),
        375,
        reason: '300 / (9/16) is 533 without the cap',
      );
    });

    test('a cinema-wide clip does not become a strip', () {
      expect(VideoBubble.rectangleHeight(300, 21 / 9), 150);
    });

    test('a player that reports no shape yet is drawn as 16:9', () {
      expect(VideoBubble.rectangleHeight(300, 0), closeTo(168.75, 0.01));
    });
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
