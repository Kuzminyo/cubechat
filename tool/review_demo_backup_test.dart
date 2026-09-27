// Builds the demo backup App Review restores instead of signing in.
//
// App Review rejected 1118 under 2.1(a): it wants an account with content
// already in it. Cubechat has no accounts, and a single review iPad has nobody
// to talk to, so the reviewer restores this file (Profile → Backup → Restore)
// and gets a throwaway identity with two contacts and a channel already
// holding messages — enough to try Report, Hide, Block and the filter.
//
// The identity is minted here and exists nowhere else; the contacts' keys are
// random and nobody holds their private halves. Written through the app's own
// controllers and BackupService, so the file is exactly what the app writes.
//
//   flutter test tool/review_demo_backup_test.dart
//
// Output: build/review-demo.cchatbackup and build/review-demo-password.txt.
// The second test restores the file into empty storage and checks it.
//
// Lives in tool/, not test/, so CI never runs it; the test-only mocks are what
// let it drive the real controllers off a phone.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/identity/nickname_controller.dart';
import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/backup/data/backup_service.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/moderation/data/terms_controller.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../test/support/hive_settle.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

final _archive = File('build/review-demo.cchatbackup');
final _passwordFile = File('build/review-demo-password.txt');

Future<String> _randomPubkeyHex() async {
  final pair = await X25519().newKeyPair();
  final pub = await pair.extractPublicKey();
  return pub.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _randomPassword() {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  final rng = Random.secure();
  return List.generate(12, (_) => alphabet[rng.nextInt(alphabet.length)])
      .join();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory phone;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    phone = await Directory.systemTemp.createTemp('cubechat_review_demo_');
    PathProviderPlatform.instance = _Paths(phone.path);
    Hive.init(phone.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (phone.existsSync()) phone.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  test('writes the App Review demo backup', () async {
    final now = DateTime.now();
    DateTime ago(Duration d) => now.subtract(d);
    var n = 0;
    Message msg(
      String chatId,
      String text, {
      required bool mine,
      required DateTime at,
      String? author,
      String? authorId,
    }) =>
        Message(
          id: 'demo${n++}',
          chatId: chatId,
          text: text,
          sentAt: at,
          isMine: mine,
          status: mine ? MessageStatus.read : MessageStatus.delivered,
          authorName: author,
          authorId: authorId,
          wireId: 'demo-wire-$n',
        );

    await container.read(termsControllerProvider.notifier).accept();
    await container.read(nicknameControllerProvider.notifier).loaded;
    await container.read(nicknameControllerProvider.notifier).set('App Review');

    final peers = container.read(knownPeersControllerProvider.notifier);
    final messages = container.read(messagesControllerProvider.notifier);
    final channels = container.read(channelControllerProvider.notifier);
    await peers.loaded;
    await messages.loaded;
    await channels.loaded;

    final anna = await _randomPubkeyHex();
    final max = await _randomPubkeyHex();
    final stranger = await _randomPubkeyHex();
    peers
      ..upsert(pubkeyHex: anna, displayName: 'Anna (demo)')
      ..upsert(pubkeyHex: max, displayName: 'Max (demo)')
      ..upsert(pubkeyHex: stranger, displayName: 'Unknown (demo)');

    // A conversation with a contact: both sides have written.
    for (final m in [
      msg(anna, 'Hi! Are you coming to the meetup on Saturday?',
          mine: false, at: ago(const Duration(days: 1, hours: 3))),
      msg(anna, 'Yes, I will be there around 6.',
          mine: true, at: ago(const Duration(days: 1, hours: 2))),
      msg(anna, 'Great. I will bring the projector.',
          mine: false, at: ago(const Duration(days: 1, hours: 2))),
      msg(anna, 'Long-press any of my messages to try Report or Hide.',
          mine: false, at: ago(const Duration(hours: 5))),
    ]) {
      messages.append(anna, m);
    }
    for (final m in [
      msg(max, 'Did you get the photos from yesterday?',
          mine: false, at: ago(const Duration(hours: 9))),
      msg(max, 'Not yet, can you send them again?',
          mine: true, at: ago(const Duration(hours: 8))),
      msg(max, 'Open my profile to block me, if you like.',
          mine: false, at: ago(const Duration(hours: 8))),
    ]) {
      messages.append(max, m);
    }
    // Somebody the user never wrote to: the offensive-content filter folds
    // this message until the user chooses to see it.
    for (final m in [
      msg(stranger, 'hey',
          mine: false, at: ago(const Duration(hours: 2, minutes: 10))),
      msg(stranger, 'answer me, you piece of shit',
          mine: false, at: ago(const Duration(hours: 2))),
    ]) {
      messages.append(stranger, m);
    }

    // A private channel: posts from other members, one of them filtered.
    final channel = await channels.join(
      'cubechat-demo',
      password: _randomPassword(),
    );
    for (final m in [
      msg(channel.name, 'Welcome to the demo channel.',
          mine: false,
          at: ago(const Duration(days: 2)),
          author: 'Anna (demo)',
          authorId: anna.substring(0, 16)),
      msg(channel.name, 'The bike ride starts at the park at 10.',
          mine: false,
          at: ago(const Duration(days: 1)),
          author: 'Max (demo)',
          authorId: max.substring(0, 16)),
      msg(channel.name, 'this ride is shit, nobody should come',
          mine: false,
          at: ago(const Duration(hours: 20)),
          author: 'Unknown (demo)',
          authorId: stranger.substring(0, 16)),
      msg(channel.name, 'Long-press a post to Report it or Hide its author.',
          mine: false,
          at: ago(const Duration(hours: 4)),
          author: 'Anna (demo)',
          authorId: anna.substring(0, 16)),
    ]) {
      messages.append(channel.name, m);
    }

    await messages.flushPending();
    await settleBackgroundStorage();

    final password = _randomPassword();
    await _archive.parent.create(recursive: true);
    if (_archive.existsSync()) _archive.deleteSync();
    await container
        .read(backupServiceProvider)
        .createFile(_archive, password: password);
    await _passwordFile.writeAsString('$password\n');
    expect(_archive.lengthSync(), greaterThan(0));
  });

  test('the demo backup restores into an empty app', () async {
    final password = (await _passwordFile.readAsString()).trim();
    await container
        .read(backupServiceProvider)
        .restoreFile(_archive, password: password);

    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;
    final chats = container.read(messagesControllerProvider);
    expect(chats.length, 4);
    expect(chats.values.expand((m) => m).length, 13);

    final peers = container.read(knownPeersControllerProvider.notifier);
    await peers.loaded;
    expect(
      container
          .read(knownPeersControllerProvider)
          .values
          .map((p) => p.displayName),
      containsAll(['Anna (demo)', 'Max (demo)', 'Unknown (demo)']),
    );

    final channels = container.read(channelControllerProvider.notifier);
    await channels.loaded;
    expect(container.read(channelControllerProvider), hasLength(1));
  });
}
