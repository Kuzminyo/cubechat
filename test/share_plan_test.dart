import 'package:cubechat/features/airdrop/data/share_inbox.dart';
import 'package:cubechat/features/share/domain/share_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Share → CubeChat" from another app used to open the app and nothing else
/// for a link, and hand files only to AirDrop. Now it goes into chats, the way
/// forwarding does — this is what each chosen chat is sent.
void main() {
  const photo = SharedFile(path: '/c/a.jpg', name: 'a.jpg', mime: 'image/jpeg');
  const pdf =
      SharedFile(path: '/c/b.pdf', name: 'b.pdf', mime: 'application/pdf');

  test('a link alone becomes one text message', () {
    const bundle = SharedBundle(text: 'https://example.com');
    expect(planShare(bundle, toChannel: false), [
      const ShareTextStep('https://example.com'),
    ]);
  });

  test('pictures go as photos, anything else as a file, text first', () {
    const bundle = SharedBundle(files: [photo, pdf], text: 'look');
    expect(planShare(bundle, toChannel: false), [
      const ShareTextStep('look'),
      const SharePictureStep(photo),
      const ShareFileStep(pdf),
    ]);
  });

  test('a room carries no files, so only text and pictures go there', () {
    const bundle = SharedBundle(files: [photo, pdf], text: 'look');
    expect(planShare(bundle, toChannel: true), [
      const ShareTextStep('look'),
      const SharePictureStep(photo),
    ]);
    expect(bundle.roomsCanTakeAll, isFalse);
    expect(const SharedBundle(files: [photo]).roomsCanTakeAll, isTrue);
  });

  test('the platform rows: files and the text that came with them', () {
    final bundle = SharedBundle.fromPlatform(
      files: [
        {'path': '/c/a.jpg', 'name': 'a.jpg', 'mime': 'image/jpeg'},
      ],
      text: '  hello  ',
    );
    expect(bundle.files.single.name, 'a.jpg');
    expect(bundle.text, 'hello');
    expect(SharedBundle.fromPlatform(files: null, text: '   ').isEmpty, isTrue);
  });
}
