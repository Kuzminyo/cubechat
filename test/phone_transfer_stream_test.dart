import 'dart:io';
import 'package:cubechat/features/backup/data/phone_transfer_socket_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('phone transfer streams a file above the former 48 MB limit', () async {
    final dir = await Directory.systemTemp.createTemp('phone_transfer_');
    const size = 49 * 1024 * 1024;
    var restored = false;
    final service = PhoneTransferService.withCallbacks(
      localHost: () async => '127.0.0.1',
      tempFile: (role) async => File('${dir.path}/$role'),
      createBackup: (file, password) async {
        final out = await file.open(mode: FileMode.write);
        await out.truncate(size);
        await out.setPosition(size - 3);
        await out.writeFrom([17, 28, 39]);
        await out.close();
      },
      restoreBackup: (file, password) async {
        expect(await file.length(), size);
        expect(
          await file.openRead(size - 3).expand((bytes) => bytes).toList(),
          [17, 28, 39],
        );
        restored = true;
      },
    );
    final session = await service.startSending();
    try {
      await service.receive(PhoneTransferPayload.tryDecode(session.payload)!);
      expect(restored, isTrue);
      expect(File('${dir.path}/receive').existsSync(), isFalse);
    } finally {
      await session.close();
      await dir.delete(recursive: true);
    }
  });
}
