import 'dart:io';

import 'package:cubechat/core/storage/hive_init.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_wipe_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('boxes open under their own types are still wiped', () async {
    // The shapes the app actually opens these with. Asking for them back as
    // Box<dynamic> throws "already open and of type ...", which is how a wipe
    // came to leave everything exactly where it was.
    final channels =
        await Hive.openBox<Map<dynamic, dynamic>>(HiveBoxes.channels);
    final messages = await Hive.openBox<List<dynamic>>(HiveBoxes.messages);
    await channels.put('#room', {'name': '#room'});
    await messages.put('chat', ['hello']);

    await HiveInit.wipeAll();

    expect(Hive.isBoxOpen(HiveBoxes.channels), isFalse);
    expect(Hive.isBoxOpen(HiveBoxes.messages), isFalse);

    // Nothing survived to be read back — which is what a transfer needs before
    // it imports somebody's real data over the top.
    final reopened =
        await Hive.openBox<Map<dynamic, dynamic>>(HiveBoxes.channels);
    expect(reopened.isEmpty, isTrue);
  });

  test('wiping a device that never opened a box is not an error', () async {
    await HiveInit.wipeAll();
    final fresh = await Hive.openBox<List<dynamic>>(HiveBoxes.messages);
    expect(fresh.isEmpty, isTrue);
  });
}
