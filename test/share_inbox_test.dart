import 'package:cubechat/features/airdrop/data/share_inbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('takes well-formed rows and cleans the names', () {
    final files = parseSharedFiles([
      {'path': '/c/a.jpg', 'name': '../a.jpg', 'mime': 'image/jpeg'},
      {'path': '/c/b.pdf', 'name': 'b.pdf'},
      {'path': 7, 'name': 'bad'},
      'nonsense',
    ]);
    expect(files, hasLength(2));
    expect(files.first.name, '_a.jpg');
    expect(files.first.mime, 'image/jpeg');
    expect(files.last.mime, 'application/octet-stream');
  });

  test('anything that is not a list is nothing', () {
    expect(parseSharedFiles(null), isEmpty);
    expect(parseSharedFiles({'path': '/x'}), isEmpty);
  });
}
