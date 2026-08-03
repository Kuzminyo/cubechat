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
  });
}
