import 'dart:convert';
import 'dart:io';

import 'package:cubechat/features/stickers/data/builtin_stickers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;
  late Uint8List bundled;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('cubechat_sticker_copy_');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documents.path,
    );
    bundled = Uint8List.fromList(<int>[1, 2, 3, 4]);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async {
        final key = utf8.decode(
          message!.buffer.asUint8List(
            message.offsetInBytes,
            message.lengthInBytes,
          ),
        );
        if (key != 'assets/stickers/cat-tired.webp') return null;
        return ByteData.sublistView(bundled);
      },
    );
  });

  tearDown(() async {
    binding.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await documents.delete(recursive: true);
  });

  test('an updated bundle is used even when a legacy copy exists', () async {
    final folder = Directory('${documents.path}/cubechat-stickers');
    await folder.create();
    final legacy = File('${folder.path}/builtin-cat-tired.webp');
    await legacy.writeAsBytes(<int>[9, 9, 9]);

    final path = await BuiltinStickers.materialize('cat-tired');
    expect(path, isNotNull);
    expect(await File(path!).readAsBytes(), orderedEquals(bundled));
    expect(path, isNot(legacy.path));
    expect(await legacy.readAsBytes(), orderedEquals(<int>[9, 9, 9]));
  });

  test('changed artwork gets a new path and preserves sent media', () async {
    final first = await BuiltinStickers.materialize('cat-tired');
    expect(first, isNotNull);
    bundled = Uint8List.fromList(<int>[5, 6, 7, 8]);
    final updated = await BuiltinStickers.materialize('cat-tired');
    expect(updated, isNot(first));
    expect(await File(updated!).readAsBytes(), orderedEquals(bundled));
    expect(await File(first!).readAsBytes(), orderedEquals(<int>[1, 2, 3, 4]));
  });

  test('the same drawing reuses its complete copy', () async {
    final first = await BuiltinStickers.materialize('cat-tired');
    final file = File(first!);
    final stamp = DateTime.utc(2020);
    await file.setLastModified(stamp);
    final again = await BuiltinStickers.materialize('cat-tired');
    expect(again, first);
    expect((await file.lastModified()).toUtc(), stamp);
  });
}
