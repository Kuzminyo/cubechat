import 'dart:io';

import 'package:cubechat/core/identity/anon_name.dart';
import 'package:cubechat/features/peers/data/contact_aliases_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolving what to call somebody', () {
    const pubkey = 'abcd1234abcd1234';

    test('with no alias, nothing changes for anyone', () {
      // The whole migration story: every call site can move to this helper
      // without changing behaviour for a user who never renames anybody.
      for (final raw in ['Roma', '', 'Anonymous']) {
        expect(
          contactDisplayName(
            alias: null,
            rawBroadcastName: raw,
            pubkeyHex: pubkey,
          ),
          displayNameForPeer(raw, pubkey),
        );
      }
    });

    test('an alias wins over the name they broadcast', () {
      // Including when they have a perfectly good name of their own — the
      // point of renaming is that your label beats theirs.
      expect(
        contactDisplayName(
          alias: 'Brother',
          rawBroadcastName: 'Roma',
          pubkeyHex: pubkey,
        ),
        'Brother',
      );
    });

    test('a peer renaming themselves cannot undo your alias', () {
      const alias = 'Brother';
      final before = contactDisplayName(
        alias: alias,
        rawBroadcastName: 'Roma',
        pubkeyHex: pubkey,
      );
      final after = contactDisplayName(
        alias: alias,
        rawBroadcastName: 'Roma 2.0',
        pubkeyHex: pubkey,
      );
      expect(before, after);
    });

    test('whitespace is not a name', () {
      expect(
        contactDisplayName(
          alias: '   ',
          rawBroadcastName: 'Roma',
          pubkeyHex: pubkey,
        ),
        'Roma',
      );
    });
  });

  group('the alias store', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_alias_test_');
      Hive.init(tempDir.path);
      container = ProviderContainer();
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can retain a Hive handle very briefly after close.
      }
    });

    test('an alias round trips and survives a reload', () async {
      final aliases = container.read(contactAliasesControllerProvider.notifier);
      await aliases.loaded;
      expect(await aliases.setAlias('aa11', '  Brother '), isTrue);
      expect(aliases.forPeer('aa11'), 'Brother');

      final reloaded = ProviderContainer();
      addTearDown(reloaded.dispose);
      final after = reloaded.read(contactAliasesControllerProvider.notifier);
      await after.loaded;
      expect(after.forPeer('aa11'), 'Brother');
    });

    test('an empty alias clears rather than storing blank', () async {
      final aliases = container.read(contactAliasesControllerProvider.notifier);
      await aliases.loaded;
      await aliases.setAlias('aa11', 'Brother');
      expect(await aliases.setAlias('aa11', '  '), isTrue);
      expect(aliases.forPeer('aa11'), isNull);
    });

    test('an over-long alias is refused, not truncated', () async {
      final aliases = container.read(contactAliasesControllerProvider.notifier);
      await aliases.loaded;
      expect(
        await aliases.setAlias('aa11', 'x' * (kContactAliasMaxLength + 1)),
        isFalse,
      );
      expect(aliases.forPeer('aa11'), isNull);
    });

    test('renaming one contact leaves the others alone', () async {
      final aliases = container.read(contactAliasesControllerProvider.notifier);
      await aliases.loaded;
      await aliases.setAlias('aa11', 'Brother');
      await aliases.setAlias('bb22', 'Work');
      await aliases.clearAlias('aa11');
      expect(aliases.forPeer('aa11'), isNull);
      expect(aliases.forPeer('bb22'), 'Work');
    });
  });
}
