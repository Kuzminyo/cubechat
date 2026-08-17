import 'dart:io';

import 'package:cubechat/features/profile/data/storage_usage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A throwaway tree standing in for the app's three roots.
({StorageRoots roots, Directory tmp}) _tree() {
  // createTempSync, not the async one: an await on the real filesystem inside a
  // fake-async test zone never completes.
  final tmp = Directory.systemTemp.createTempSync('cubechat-storage-test');
  Directory sub(String path) =>
      Directory('${tmp.path}${Platform.pathSeparator}$path')
        ..createSync(recursive: true);
  return (
    roots: StorageRoots(
      documents: sub('docs'),
      support: sub('support'),
      temp: sub('cache'),
    ),
    tmp: tmp,
  );
}

void _write(Directory dir, String name, int bytes) {
  Directory(dir.path).createSync(recursive: true);
  File('${dir.path}${Platform.pathSeparator}$name')
      .writeAsBytesSync(List<int>.filled(bytes, 0));
}

Directory _under(Directory root, String name) =>
    Directory('${root.path}${Platform.pathSeparator}$name');

void main() {
  group('scanStorage', () {
    test('measures every pile and adds up to the total', () async {
      final t = _tree();
      addTearDown(() => t.tmp.deleteSync(recursive: true));

      _write(_under(t.roots.documents, 'cubechat-images'), 'a.jpg', 3000);
      _write(_under(t.roots.documents, 'cubechat-sent'), 'b.jpg', 2000);
      _write(_under(t.roots.documents, 'cubechat-audio'), 'v.aac', 1000);
      _write(t.roots.temp, 'export.txt', 500);

      final report = await scanStorage(t.roots);

      // Sent and received photos are one pile to a person, two directories on
      // disk.
      expect(report.bytesOf(StorageCategory.photos), 5000);
      expect(report.bytesOf(StorageCategory.voice), 1000);
      expect(report.bytesOf(StorageCategory.cache), 500);
      expect(report.totalBytes, 6500);
      expect(report.shareOf(StorageCategory.photos), closeTo(5000 / 6500, 1e-9));
    });

    test('a fresh install measures zero rather than throwing', () async {
      final t = _tree();
      addTearDown(() => t.tmp.deleteSync(recursive: true));

      final report = await scanStorage(t.roots);
      expect(report.totalBytes, 0);
      // Every category is still present — a legend that grows as things are
      // written would reflow the screen under the reader.
      expect(report.buckets, hasLength(StorageCategory.values.length));
      expect(report.shareOf(StorageCategory.photos), 0);
      expect(report.visible, isEmpty);
    });

    test('history counts Hive and not whatever else shares that directory',
        () async {
      final t = _tree();
      addTearDown(() => t.tmp.deleteSync(recursive: true));

      _write(t.roots.support, 'messages.hive', 4000);
      _write(t.roots.support, 'messages.lock', 100);
      // A plugin's own file. Counting it would put bytes nobody can account for
      // in the one row that cannot be checked by opening a folder.
      _write(t.roots.support, 'some_plugin_cache.db', 9000);

      final report = await scanStorage(t.roots);
      expect(report.bytesOf(StorageCategory.history), 4100);
    });

    test('slivers are left out of the chart but stay in the legend', () async {
      final t = _tree();
      addTearDown(() => t.tmp.deleteSync(recursive: true));

      _write(_under(t.roots.documents, 'cubechat-images'), 'big.jpg', 1000000);
      _write(_under(t.roots.documents, 'cubechat-audio'), 'tiny.aac', 100);

      final report = await scanStorage(t.roots);
      final drawn = report.visible.map((b) => b.category);
      expect(drawn, contains(StorageCategory.photos));
      expect(drawn, isNot(contains(StorageCategory.voice)),
          reason: 'a slice that thin is a border and nothing else');
      expect(report.bytesOf(StorageCategory.voice), 100);
    });
  });

  group('clearStorage', () {
    test('sweeps what was asked for and leaves the rest alone', () async {
      final t = _tree();
      addTearDown(() => t.tmp.deleteSync(recursive: true));

      _write(_under(t.roots.documents, 'cubechat-images'), 'a.jpg', 3000);
      _write(t.roots.temp, 'export.txt', 500);

      final freed = await clearStorage({StorageCategory.cache}, t.roots);
      expect(freed, 500);

      final after = await scanStorage(t.roots);
      expect(after.bytesOf(StorageCategory.cache), 0);
      expect(after.bytesOf(StorageCategory.photos), 3000,
          reason: 'clearing the cache must not touch anybody\'s photos');
    });

    test('keeps the directories, only empties them', () async {
      final t = _tree();
      addTearDown(() => t.tmp.deleteSync(recursive: true));

      final images = _under(t.roots.documents, 'cubechat-images');
      _write(images, 'a.jpg', 3000);

      await clearStorage({StorageCategory.photos}, t.roots);
      expect(images.existsSync(), isTrue,
          reason: 'the code that writes here expects the directory to be there');
      expect(images.listSync(), isEmpty);
    });

    test('refuses to delete history even when asked', () async {
      final t = _tree();
      addTearDown(() => t.tmp.deleteSync(recursive: true));

      _write(t.roots.support, 'messages.hive', 4000);

      final freed = await clearStorage({StorageCategory.history}, t.roots);
      expect(freed, 0);
      final after = await scanStorage(t.roots);
      expect(after.bytesOf(StorageCategory.history), 4000,
          reason: 'emptying conversations is Emergency Wipe, not a tick box');
    });

    test('only the cache is free to delete; the rest costs something', () {
      // The screen leans on this to decide what is ticked when it opens, and
      // what has to be explained before it is.
      expect(StorageCategory.cache.recovery, StorageRecovery.free);
      expect(StorageCategory.history.clearable, isFalse);
      for (final category in StorageCategory.values) {
        if (category == StorageCategory.cache) continue;
        expect(category.recovery, isNot(StorageRecovery.free),
            reason: '${category.name} would be swept with no warning');
      }
    });
  });

  group('formatBytes', () {
    test('reads like the phone\'s own storage screen', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1500), '2 KB');
      expect(formatBytes(616200000), '616.2 MB');
      expect(formatBytes(1800000000), '1.8 GB');
      expect(formatBytes(5600000000), '5.6 GB');
    });
  });
}
