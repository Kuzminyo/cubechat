/// Every wait and limit AirDrop has, in one place — the design in
/// docs/superpowers/specs/2026-09-22-airdrop-design.md sets each of them.
abstract final class AirDropRules {
  /// An offer that draws no automatic "seen" in this long probably went to an
  /// old build, which drops the frame without a word.
  static const Duration seenWithin = Duration(seconds: 10);

  /// A request nobody answers is declined for them after this.
  static const Duration answerWithin = Duration(seconds: 60);

  /// An accepted transfer that receives nothing for this long is interrupted.
  static const Duration stallAfter = Duration(seconds: 60);

  /// An outgoing Wi-Fi file that reports no progress for this long has lost
  /// its connection. Without it a phone that walked out of range leaves the
  /// socket's flush waiting until TCP gives up, which is minutes. A local
  /// network moves a 1 MiB read in well under a second, so twenty is only
  /// ever a dead link. It also covers the wait for "kept" after the last
  /// chunk, where the receiver only has to rename the file.
  static const Duration wifiStallAfter = Duration(seconds: 20);

  /// How long an accepted offer stays accepted, so a retry after a dropped
  /// link goes through without asking again.
  static const Duration acceptedFor = Duration(minutes: 10);

  /// "Everyone" switches itself back to contacts after this.
  static const Duration everyoneFor = Duration(minutes: 10);

  static const int historyCap = 200;

  static const int declinesBeforeBan = 3;
  static const Duration firstBan = Duration(minutes: 10);
  static const Duration maxBan = Duration(hours: 24);

  /// A stranger's record is forgotten after a day without requests.
  static const Duration forgetAfter = Duration(hours: 24);

  /// Past this much in one go the sender is warned Bluetooth will be slow:
  /// at the ~40 KB/s a phone link really carries, twenty megabytes is minutes.
  static const int longOverBluetoothBytes = 20 * 1024 * 1024;
}
