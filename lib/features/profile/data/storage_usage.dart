import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// What the app is actually using the phone's disk for.
///
/// Worth having for a reason this app has and most messengers do not: **there
/// is no cloud behind any of it.** Telegram can offer to empty the lot because
/// every byte is also on a server; here, a received photo exists on exactly two
/// phones and a voice note on two, and clearing one is the nearer half of
/// deleting it. So this screen has to be able to say what a given pile *is*
/// before anybody is asked whether to sweep it away — which needs the piles
/// measured, named, and told apart by how recoverable they are.
enum StorageCategory {
  /// Photos, both directions. Two directories because a sent photo is kept
  /// separately from a received one, but to a person they are "photos".
  photos(
    dirs: ['cubechat-images', 'cubechat-sent'],
    icon: Icons.photo_rounded,
    hue: 0,
    recovery: StorageRecovery.gone,
  ),

  voice(
    dirs: ['cubechat-audio'],
    icon: Icons.mic_rounded,
    hue: 42,
    recovery: StorageRecovery.gone,
  ),

  /// Files received. The outbox — our own copies of what we sent — is counted
  /// separately below, because the two differ entirely in what losing them
  /// costs.
  files(
    dirs: ['cubechat-inbox'],
    icon: Icons.insert_drive_file_rounded,
    hue: 84,
    recovery: StorageRecovery.askSender,
  ),

  /// Copies of what we sent, kept so a peer who cleared theirs can ask for it
  /// again. Nothing of ours is lost by clearing it; somebody else's ability to
  /// get their file back is.
  outbox(
    dirs: ['cubechat-outbox'],
    icon: Icons.outbox_rounded,
    hue: 126,
    recovery: StorageRecovery.costsThem,
  ),

  stickers(
    dirs: ['cubechat-stickers'],
    icon: Icons.emoji_emotions_rounded,
    hue: 168,
    recovery: StorageRecovery.gone,
  ),

  saved(
    dirs: ['cubechat-saved'],
    icon: Icons.bookmark_rounded,
    hue: 210,
    recovery: StorageRecovery.gone,
  ),

  wallpapers(
    dirs: ['cubechat-wallpaper'],
    icon: Icons.wallpaper_rounded,
    hue: 252,
    recovery: StorageRecovery.gone,
  ),

  /// Conversations and keys. Shown so the total is the truth, never offered for
  /// clearing: emptying it is Emergency Wipe, which is a different decision
  /// made on a different screen with a different warning.
  history(
    dirs: <String>[],
    icon: Icons.forum_rounded,
    hue: 294,
    recovery: StorageRecovery.never,
  ),

  /// Scratch space — exports staged on their way to another app, thumbnails,
  /// whatever the OS has not swept yet. The only pile that is genuinely free to
  /// delete, and therefore the only one ticked by default.
  cache(
    dirs: <String>[],
    icon: Icons.cached_rounded,
    hue: 336,
    recovery: StorageRecovery.free,
  );

  const StorageCategory({
    required this.dirs,
    required this.icon,
    required this.hue,
    required this.recovery,
  });

  /// Directory names under the documents root. Empty for the two categories
  /// that live somewhere else entirely — see [StorageRoots].
  final List<String> dirs;

  final IconData icon;

  /// Degrees to rotate the palette's own colour by for this slice.
  ///
  /// Derived rather than hard-coded so the chart follows the theme: on the
  /// emerald palette it is a wheel of greens through to magenta, on rose a
  /// wheel starting from rose. Fixed offsets keep a category the same relative
  /// colour whatever the theme, which is what makes the legend learnable.
  final double hue;

  final StorageRecovery recovery;

  /// Whether this pile may be swept from this screen at all.
  bool get clearable => recovery != StorageRecovery.never;
}

/// What it costs to delete a pile — the thing this screen exists to say.
enum StorageRecovery {
  /// Nothing is lost. Temporary files only.
  free,

  /// The bytes are gone from this phone and there is no copy anywhere but the
  /// sender's device, if they still have it.
  gone,

  /// Gone from here, but the app can ask the sender for it again — see
  /// `InnerPayloadType.mediaRequest`.
  askSender,

  /// Ours to delete, but it is what lets *them* ask us for a file again.
  costsThem,

  /// Not offered here at all.
  never,
}

/// Where on disk each pile lives.
///
/// Injected rather than looked up inside the scan so the whole thing can be
/// pointed at a temporary directory in a test — the alternative is a scanner
/// that can only be exercised on a phone, which is to say not exercised.
@immutable
class StorageRoots {
  const StorageRoots({
    required this.documents,
    required this.support,
    required this.temp,
  });

  /// Media the user sent and received. Survives everything but a reinstall.
  final Directory documents;

  /// Hive's home — conversations, contacts, keys.
  final Directory support;

  /// Scratch. The OS may empty this whenever it likes.
  final Directory temp;

  static Future<StorageRoots> resolve() async => StorageRoots(
        documents: await getApplicationDocumentsDirectory(),
        support: await getApplicationSupportDirectory(),
        temp: await getTemporaryDirectory(),
      );
}

/// One measured pile.
@immutable
class StorageBucket {
  const StorageBucket({
    required this.category,
    required this.bytes,
    required this.files,
  });

  final StorageCategory category;
  final int bytes;
  final int files;

  bool get isEmpty => bytes == 0;
}

/// Everything, measured.
@immutable
class StorageReport {
  const StorageReport(this.buckets);

  /// Every category, in enum order, including the empty ones — a legend that
  /// changes length as things are deleted is a legend that jumps about.
  final List<StorageBucket> buckets;

  static const StorageReport empty = StorageReport(<StorageBucket>[]);

  int get totalBytes =>
      buckets.fold<int>(0, (sum, bucket) => sum + bucket.bytes);

  int bytesOf(StorageCategory category) => buckets
      .firstWhere(
        (b) => b.category == category,
        orElse: () => StorageBucket(category: category, bytes: 0, files: 0),
      )
      .bytes;

  /// This category's share of the whole, 0..1. Zero when nothing is stored at
  /// all, rather than a division by zero.
  double shareOf(StorageCategory category) {
    final total = totalBytes;
    if (total == 0) return 0;
    return bytesOf(category) / total;
  }

  /// The piles worth drawing: anything at all, largest first.
  ///
  /// A slice under a fifth of a percent is invisible at any chart size and
  /// still costs a border, so the chart takes this list and the legend takes
  /// [buckets].
  List<StorageBucket> get visible {
    final total = totalBytes;
    if (total == 0) return const <StorageBucket>[];
    final shown = buckets.where((b) => b.bytes / total >= 0.002).toList();
    shown.sort((a, b) => b.bytes.compareTo(a.bytes));
    return shown;
  }
}

/// Measure every pile.
///
/// Walks rather than asks: there is no index of what the app has written, and
/// building one would be a second source of truth to keep in step with the
/// disk. A few hundred files is milliseconds, and this runs when a person opens
/// a settings screen and not on any hot path.
Future<StorageReport> scanStorage(StorageRoots roots) async {
  final buckets = <StorageBucket>[];
  for (final category in StorageCategory.values) {
    var bytes = 0;
    var files = 0;
    for (final dir in _directoriesFor(category, roots)) {
      final measured = await _measure(dir, only: _filterFor(category));
      bytes += measured.$1;
      files += measured.$2;
    }
    buckets.add(
      StorageBucket(category: category, bytes: bytes, files: files),
    );
  }
  return StorageReport(buckets);
}

/// Delete the contents of [categories], and answer how many bytes went.
///
/// Files only — the directories stay, because the code that writes into them
/// expects them to exist and re-creating one on the next write is a race nobody
/// needs. [StorageCategory.history] is refused outright even if asked for: this
/// screen is not a way to delete somebody's conversations by ticking a box.
Future<int> clearStorage(
  Set<StorageCategory> categories,
  StorageRoots roots,
) async {
  var freed = 0;
  for (final category in categories) {
    if (!category.clearable) continue;
    for (final dir in _directoriesFor(category, roots)) {
      freed += await _deleteContents(dir, only: _filterFor(category));
    }
  }
  return freed;
}

List<Directory> _directoriesFor(StorageCategory category, StorageRoots roots) {
  switch (category) {
    case StorageCategory.history:
      return [roots.support];
    case StorageCategory.cache:
      return [roots.temp];
    default:
      return [
        for (final name in category.dirs)
          Directory('${roots.documents.path}${Platform.pathSeparator}$name'),
      ];
  }
}

/// Which files in a directory belong to a category.
///
/// Only history needs one: Hive shares the support directory with whatever else
/// the platform puts there, and counting a plugin's own files as "your
/// conversations" would be a lie in the one row nobody can verify.
bool Function(File)? _filterFor(StorageCategory category) {
  if (category != StorageCategory.history) return null;
  return (file) {
    final name = file.path.toLowerCase();
    return name.endsWith('.hive') || name.endsWith('.lock');
  };
}

/// (bytes, file count) under [dir], recursively. A directory that does not
/// exist measures zero rather than throwing — most of them will not exist on a
/// fresh install.
Future<(int, int)> _measure(Directory dir, {bool Function(File)? only}) async {
  if (!await dir.exists()) return (0, 0);
  var bytes = 0;
  var files = 0;
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (only != null && !only(entity)) continue;
      try {
        bytes += await entity.length();
        files++;
      } on FileSystemException {
        // Vanished between the listing and the stat, or is not ours to read.
        // A file we cannot measure is not worth failing the whole screen over.
      }
    }
  } on FileSystemException {
    // The directory itself went away mid-walk.
  }
  return (bytes, files);
}

Future<int> _deleteContents(Directory dir, {bool Function(File)? only}) async {
  if (!await dir.exists()) return 0;
  var freed = 0;
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (only != null && !only(entity)) continue;
      try {
        final size = await entity.length();
        await entity.delete();
        freed += size;
      } on FileSystemException {
        // Locked, open, or already gone. Skip it and keep going: a single
        // stubborn file must not abandon the rest of the sweep.
      }
    }
  } on FileSystemException {
    // Nothing left to walk.
  }
  return freed;
}

/// "1,80 GB" / "616,2 MB" / "311 KB".
///
/// Decimal units, matching what a phone's own storage screen says, so the two
/// numbers a user compares are in the same units. One decimal place from a
/// megabyte up, none below — "0,3 KB" is noise.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  // Kilobytes get no decimal: at that size the fraction is never the point.
  final digits = unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
