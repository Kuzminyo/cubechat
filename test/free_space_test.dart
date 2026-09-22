import 'package:cubechat/core/util/free_space.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cubechat/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads the number the platform gives', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'freeBytes');
      return 123456;
    });
    expect(await FreeSpace.bytes(), 123456);
  });

  // Web, desktop and a build whose native half is missing all land here.
  // Unknown must never read as "no space", or every offer would be refused.
  test('says nothing when nobody answers', () async {
    expect(await FreeSpace.bytes(), isNull);
  });
}
