import 'dart:io';

import 'package:cubechat/features/chats/presentation/archive_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Leaving the archive without having picked anything.
///
/// The screen clears the shared selection as it goes, through a notifier it
/// was meant to have taken while it was alive. The field was a lazy `late
/// final`, so with nothing ever picked its first read was in `dispose` — and a
/// phone on 1068 logged "Cannot use ref after the widget was disposed" from
/// exactly there.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_archive_ui_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  testWidgets('closing the archive with nothing picked does not throw',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ArchiveScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SizedBox())),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
