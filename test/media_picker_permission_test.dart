import 'package:cubechat/features/chat/presentation/widgets/media_picker_sheet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test('Android explains why a video-only gallery has no photos', () {
    expect(
      galleryNeedsPhotoPermissionNotice(true, PermissionStatus.denied),
      isTrue,
    );
    expect(
      galleryNeedsPhotoPermissionNotice(
        true,
        PermissionStatus.permanentlyDenied,
      ),
      isTrue,
    );
  });

  test('full and selected-photo access need no video-only warning', () {
    expect(
      galleryNeedsPhotoPermissionNotice(true, PermissionStatus.granted),
      isFalse,
    );
    expect(
      galleryNeedsPhotoPermissionNotice(true, PermissionStatus.limited),
      isFalse,
    );
    expect(
      galleryNeedsPhotoPermissionNotice(false, PermissionStatus.denied),
      isFalse,
    );
  });
}
