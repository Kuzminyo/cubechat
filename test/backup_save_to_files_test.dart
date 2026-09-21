import 'dart:io';

import 'package:cubechat/core/util/open_in.dart';
import 'package:cubechat/features/backup/data/backup_service.dart';
import 'package:cubechat/features/backup/presentation/backup_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Writes a few bytes where the real one would write the archive — what is
/// under test is where the file goes next, not what is in it.
class _FakeBackupService extends BackupService {
  _FakeBackupService(super.ref);

  @override
  Future<void> createFile(File destination, {required String password}) async {
    destination.writeAsBytesSync(const [0x43, 0x43, 0x42, 0x4b]);
  }
}

/// "Не открывает, куда сохранить, а отправить открывает."
///
/// When the backup took in photos and video, the phone path stopped using the
/// save screen — it wanted the archive as bytes — and went to the share sheet,
/// which only sends. Nothing on a phone could put the backup in a folder any
/// more. Both are offered now, and saving is the system's own save screen with
/// a path, not the bytes, crossing the channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');

  late Directory phone;

  setUp(() async {
    phone = await Directory.systemTemp.createTemp('cubechat_save_as_');
    PathProviderPlatform.instance = _FakePathProvider(phone.path);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(OpenIn.channel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
    try {
      if (phone.existsSync()) phone.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds a just-closed file briefly.
    }
  });

  Future<void> realWork(WidgetTester tester) async {
    // Staging the archive is real file work, which the test clock never does.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('on a phone, a backup can be saved to a folder again',
      (tester) async {
    // Set and cleared inside the body: flutter_test checks its debug
    // variables before tearDown runs.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    var stagedExisted = false;
    messenger.setMockMethodCallHandler(OpenIn.channel, (call) async {
      calls.add(call);
      final path = (call.arguments as Map)['path'] as String;
      // The platform copies from this path, so it has to be there while the
      // save screen is up — deleted only once the answer is in.
      stagedExisted = File(path).existsSync();
      return 'saved';
    });
    var shared = false;
    messenger.setMockMethodCallHandler(shareChannel, (_) async {
      shared = true;
      return 'dev.fluttercommunity.plus/share/unavailable';
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backupServiceProvider.overrideWith(_FakeBackupService.new),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: BackupScreen(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Create backup').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'correct horse');
    await tester.enterText(fields.at(1), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await tester.pump();
    await realWork(tester);

    // Two ways out, and the one that was missing is first.
    expect(find.text('Save to Files'), findsOneWidget);
    expect(find.text('Send to an app'), findsOneWidget);

    await tester.tap(find.text('Save to Files'));
    await tester.pump();
    await realWork(tester);

    expect(calls.map((c) => c.method), ['saveAs']);
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(args.keys, unorderedEquals(['path', 'name']));
    expect(args['name'], matches(RegExp(r'^cubechat-\d{4}-\d{2}-\d{2}\.cchatbackup$')));
    expect(stagedExisted, isTrue);
    expect(shared, isFalse, reason: 'saving is not sending');
    expect(find.text('Encrypted backup saved'), findsOneWidget);
    // The toast dismisses itself on a timer; let it, so nothing is pending.
    await tester.pump(const Duration(seconds: 5));
    debugDefaultTargetPlatformOverride = null;
  });
}
