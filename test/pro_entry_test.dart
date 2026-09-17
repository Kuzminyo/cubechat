import 'dart:io';

import 'package:cubechat/core/routing/app_router.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Walks nested routes: the screens hang off a shell, not off the top level.
bool _hasPath(List<RouteBase> routes, String path) {
  for (final route in routes) {
    if (route is GoRoute && route.path == path) return true;
    if (_hasPath(route.routes, path)) return true;
  }
  return false;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('cubechat_pro_entry_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('the profile offers one way in to Pro', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          // ProfileScreen lives inside the shell and returns no Scaffold of
          // its own, so the ink in its rows has no Material ancestor here
          // unless the test supplies one.
          home: const Scaffold(body: ProfileScreen()),
        ),
      ),
    );
    await tester.pump();

    // The screen holds more than one Scrollable; scrollUntilVisible has to be
    // told which, or it asks for `single` and throws on "too many elements".
    await tester.scrollUntilVisible(
      find.text('cubechat Pro'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('cubechat Pro'), findsOneWidget);
  });

  test('the route the row pushes actually exists', () {
    // The row above pushes '/pro'. A row pointing at a path nobody registered
    // compiles, passes the widget test, and does nothing on the phone.
    expect(_hasPath(buildRouter().configuration.routes, '/pro'), isTrue);
  });
}
