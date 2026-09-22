import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/backup/data/backup_filter.dart';
import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("AirDrop's own keys stay on the phone; everything else goes", () {
    expect(backupKeeps(HiveBoxes.settings, 'airdrop.history.v1'), isFalse);
    expect(backupKeeps(HiveBoxes.settings, 'airdrop.spam.v1'), isFalse);
    expect(backupKeeps(HiveBoxes.settings, 'airdrop.everyoneUntil'), isFalse);
    expect(backupKeeps(HiveBoxes.settings, 'discovery.discoverable'), isTrue);
    expect(backupKeeps(HiveBoxes.messages, 'airdrop.whatever'), isTrue);
  });

  test('the transfer list travels without its AirDrop rows', () {
    final rows = [
      {'id': 'a', 'source': 'airdrop'},
      {'id': 'b'},
      {'id': 'c', 'source': 'chat'},
    ];
    final kept = backupValue(
      HiveBoxes.settings,
      FileTransferController.storageKey,
      rows,
    )! as List;
    expect([for (final r in kept) (r as Map)['id']], ['b', 'c']);
    expect(backupValue(HiveBoxes.settings, 'other', rows), same(rows));
  });
}
