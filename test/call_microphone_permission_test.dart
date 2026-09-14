import 'package:cubechat/features/call/data/call_microphone_permission.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test('already granted microphone does not request again', () async {
    var requests = 0;
    expect(
        await requestCallMicrophonePermission(
          check: () async => PermissionStatus.granted,
          request: () async {
            requests++;
            return PermissionStatus.denied;
          },
        ),
        isTrue);
    expect(requests, 0);
  });

  test('first grant is accepted and a genuine refusal is preserved', () async {
    for (final result in [
      PermissionStatus.granted,
      PermissionStatus.denied,
      PermissionStatus.permanentlyDenied,
      PermissionStatus.restricted
    ]) {
      expect(
          await requestCallMicrophonePermission(
            check: () async => PermissionStatus.denied,
            request: () async => result,
          ),
          result == PermissionStatus.granted);
    }
  });

  test('permission changed in Settings is read again on the next call',
      () async {
    var current = PermissionStatus.permanentlyDenied;
    Future<bool> attempt() => requestCallMicrophonePermission(
          check: () async => current,
          request: () async => current,
        );
    expect(await attempt(), isFalse);
    current = PermissionStatus.granted;
    expect(await attempt(), isTrue);
  });
}
