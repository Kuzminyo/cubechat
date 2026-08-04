import 'package:cubechat/core/utils/file_mime.dart';
import 'package:cubechat/features/chat/presentation/widgets/file_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes', () {
    test('shows plain bytes below a kilobyte', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
    });

    test('uses binary units, matching what a file manager shows', () {
      // 1000 B is not a kilobyte here; a mismatch with the platform's own
      // file listing reads as a bug in the app.
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('keeps one decimal below ten and drops it above', () {
      // "9.4 MB" is useful precision; "94.3 MB" is noise.
      expect(formatBytes((9.4 * 1024 * 1024).round()), '9.4 MB');
      expect(formatBytes((94.3 * 1024 * 1024).round()), '94 MB');
    });

    test('stops at gigabytes rather than inventing a unit', () {
      expect(formatBytes(5 * 1024 * 1024 * 1024), endsWith('GB'));
    });
  });

  group('fileMimeType', () {
    test('routes common image files to gallery-capable handlers', () {
      expect(fileMimeType('photo.jpg'), 'image/jpeg');
      expect(fileMimeType('PHOTO.JPEG'), 'image/jpeg');
      expect(fileMimeType('screenshot.png'), 'image/png');
    });

    test('replaces an unhelpful generic type using the extension', () {
      expect(
        fileMimeType(
          'photo.png',
          declaredMime: 'application/octet-stream',
        ),
        'image/png',
      );
    });

    test('keeps a specific type supplied by the sender', () {
      expect(
        fileMimeType('download.bin', declaredMime: 'application/pdf'),
        'application/pdf',
      );
    });

    test('names the document formats people actually send', () {
      // This is where the table's gaps were felt. A .docx announced as
      // octet-stream matches no handler at all, so the phone reported that
      // nothing could open a file every phone can open.
      expect(
        fileMimeType('резюме.docx'),
        'application/vnd.openxmlformats-officedocument.wordprocessingml'
        '.document',
      );
      expect(fileMimeType('конспект.doc'), 'application/msword');
      expect(
        fileMimeType('budget.xlsx'),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      expect(fileMimeType('notes.md'), 'text/markdown');
      expect(fileMimeType('archive.rar'), 'application/vnd.rar');
      expect(
        fileMimeType('cubechat.apk'),
        'application/vnd.android.package-archive',
      );
      expect(fileMimeType('clip.mkv'), 'video/x-matroska');
    });

    test('an extension we do not know still resolves to nothing', () {
      // Nothing is the honest answer, and the caller turns it into "let the
      // platform work it out" rather than into a type nothing can open.
      expect(fileMimeType('weird.qqq'), 'application/octet-stream');
      expect(isUnknownMime(fileMimeType('weird.qqq')), isTrue);
      expect(isUnknownMime(fileMimeType('резюме.docx')), isFalse);
      expect(isUnknownMime(null), isTrue);
      expect(isUnknownMime(''), isTrue);
    });
  });
}
