import 'dart:io';

import 'package:cubechat/core/util/media_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Stands in for the app's container, which is the thing that moves.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory container;

  setUp(() async {
    container = await Directory.systemTemp.createTemp('cubechat_container_');
    PathProviderPlatform.instance = _FakePathProvider(container.path);
    await MediaPaths.init();
  });

  tearDown(() {
    try {
      if (container.existsSync()) container.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a handle briefly.
    }
  });

  String sep(List<String> parts) => parts.join(Platform.pathSeparator);

  test('a path inside the current container is left alone', () {
    final path = sep([container.path, 'cubechat-audio', 'a.m4a']);
    expect(MediaPaths.repair(path), path);
  });

  test('a path from a previous container is re-pointed at this one', () async {
    // The exact shape of the bug on iOS: the app is reinstalled, the container
    // UUID changes, and every path recorded against the old one is dead while
    // the bytes sit in the new one under the same relative layout.
    final dir = Directory(sep([container.path, 'cubechat-audio']))
      ..createSync(recursive: true);
    final real = File(sep([dir.path, 'note.m4a']))..writeAsBytesSync([1, 2, 3]);

    const stale =
        '/var/mobile/Containers/Data/Application/OLD-UUID/Documents'
        '/cubechat-audio/note.m4a';
    expect(MediaPaths.repair(stale), real.path);
  });

  test('a file that is genuinely gone keeps its original path', () {
    // So the bubble still reports it missing rather than pointing somewhere
    // plausible-looking that is equally empty.
    const stale = '/var/mobile/Containers/Data/Application/OLD/Documents'
        '/cubechat-images/deleted.jpg';
    expect(MediaPaths.repair(stale), stale);
  });

  test('repair reaches media written by builds that used the cache', () async {
    // Old rows point into Library/Caches/cubechat/audio. The last two segments
    // are all the rebuild needs, so a file that has since been written to the
    // current audio directory under the same name is still found.
    final dir = Directory(sep([container.path, 'audio']))
      ..createSync(recursive: true);
    final real = File(sep([dir.path, 'rec.m4a']))..writeAsBytesSync([9]);

    const legacy = '/var/mobile/Containers/Data/Application/OLD'
        '/Library/Caches/cubechat/audio/rec.m4a';
    expect(MediaPaths.repair(legacy), real.path);
  });

  test('null and empty survive untouched', () {
    expect(MediaPaths.repairOrNull(null), isNull);
    expect(MediaPaths.repair(''), '');
  });
}
