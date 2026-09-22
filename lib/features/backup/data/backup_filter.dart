import '../../../core/storage/hive_init.dart';
import '../../files/data/file_transfer_controller.dart';

/// Whether a stored value goes into a backup or a phone transfer.
///
/// AirDrop's history, its "everyone" window and its bans stay on this phone —
/// the design says so, and the files the history points at live in
/// `airdrop/`, which neither the backup nor the transfer takes.
bool backupKeeps(String box, Object? key) => !(box == HiveBoxes.settings &&
    key is String &&
    key.startsWith('airdrop.'));

/// The value as a backup carries it: the transfer list without its AirDrop
/// rows, whose files are not carried either.
Object? backupValue(String box, Object? key, Object? value) {
  if (box != HiveBoxes.settings ||
      key != FileTransferController.storageKey ||
      value is! List) {
    return value;
  }
  return [
    for (final row in value)
      if (!(row is Map && row['source'] == FileTransferSource.airdrop.name))
        row,
  ];
}
