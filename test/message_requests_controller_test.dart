import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/chat/data/conversation_settings_controller.dart';
import 'package:cubechat/features/chats/data/message_requests_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/hive_settle.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final containers = <ProviderContainer>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    dir = await Directory.systemTemp.createTemp('cubechat_requests_');
    PathProviderPlatform.instance = _Paths(dir.path);
    Hive.init(dir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    for (final c in containers) {
      c.dispose();
    }
    containers.clear();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  ProviderContainer fresh() {
    final c = ProviderContainer();
    containers.add(c);
    return c;
  }

  test('pending, accept, drop and clearPending move people as they say',
      () async {
    final c = fresh();
    final n = c.read(messageRequestsProvider.notifier);
    await n.loaded;
    await n.markPending('a');
    expect(c.read(messageRequestsProvider).pending, {'a'});
    await n.accept('a');
    expect(c.read(messageRequestsProvider).pending, isEmpty);
    expect(c.read(messageRequestsProvider).accepted, {'a'});
    await n.markPending('a');
    expect(c.read(messageRequestsProvider).pending, isEmpty,
        reason: 'an accepted person never becomes a request again');
    await n.drop('a');
    expect(c.read(messageRequestsProvider).accepted, isEmpty);
    await n.markPending('b');
    await n.markPending('c');
    await n.accept('c');
    await n.clearPending();
    expect(c.read(messageRequestsProvider).pending, isEmpty);
    expect(c.read(messageRequestsProvider).accepted, {'c'});
  });

  test('requests survive a restart', () async {
    final first = fresh();
    final n = first.read(messageRequestsProvider.notifier);
    await n.loaded;
    await n.markPending('b');
    await n.accept('x');
    final second = fresh();
    await second.read(messageRequestsProvider.notifier).loaded;
    expect(second.read(messageRequestsProvider).pending, {'b'});
    expect(second.read(messageRequestsProvider).accepted, {'x'});
  });

  test('a pending stranger gets no read receipts and cannot ring', () async {
    final c = fresh();
    final n = c.read(messageRequestsProvider.notifier);
    await n.loaded;
    await n.markPending('p');
    final settings = c.read(conversationSettingsControllerProvider.notifier);
    expect(settings.sharesReadReceiptsWith('p'), isFalse);
    expect(settings.acceptsCallsFrom('p'), isFalse);
    await n.accept('p');
    expect(settings.sharesReadReceiptsWith('p'), isTrue);
    expect(settings.acceptsCallsFrom('p'), isTrue);
  });
}
