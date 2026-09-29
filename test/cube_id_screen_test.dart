import 'dart:io';

import 'package:cubechat/features/cube_id/data/cube_id_client.dart';
import 'package:cubechat/features/cube_id/data/cube_id_controller.dart';
import 'package:cubechat/features/cube_id/presentation/cube_id_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

class _FakeCubeId extends CubeIdController {
  _FakeCubeId(this.initial, this.claimResult);
  final CubeIdState initial;
  final CubeIdResult claimResult;
  final claimed = <String>[];
  var released = 0;

  @override
  CubeIdState build() => initial;

  @override
  Future<CubeIdResult> claim(String raw) async {
    claimed.add(raw);
    if (claimResult is CubeIdOk) state = CubeIdState(name: raw);
    return claimResult;
  }

  @override
  Future<CubeIdResult> release({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    released++;
    state = CubeIdState.empty;
    return const CubeIdOk(null);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_cubeid_ui_');
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

  Widget app(_FakeCubeId fake, List<String> availabilityCalls) => ProviderScope(
        overrides: [
          cubeIdControllerProvider.overrideWith(() => fake),
          cubeIdClientProvider.overrideWithValue(
            CubeIdClient(
              http: (m, u, {body}) async {
                availabilityCalls.add(u.path);
                return (status: 200, body: '{"available":true}');
              },
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const CubeIdScreen(),
        ),
      );

  testWidgets('a bad name is refused locally; a good one is checked once',
      (tester) async {
    final calls = <String>[];
    final fake = _FakeCubeId(CubeIdState.empty, const CubeIdOk('dima'));
    await tester.pumpWidget(app(fake, calls));
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Only a–z, 0–9 and _, 3–20 characters'), findsOneWidget);
    expect(calls, isEmpty);

    await tester.enterText(find.byType(TextField), 'dim');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'dima');
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls, ['/v1/available/dima']);
    expect(find.text('Available'), findsOneWidget);

    await tester.tap(find.text('Take this name'));
    await tester.pump();
    await tester.pump();
    expect(fake.claimed, ['dima']);
    expect(find.text('@dima'), findsOneWidget);
  });

  testWidgets('a taken name says so', (tester) async {
    final fake = _FakeCubeId(CubeIdState.empty, const CubeIdRefused('taken'));
    await tester.pumpWidget(app(fake, []));
    await tester.enterText(find.byType(TextField), 'dima');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Take this name'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Taken'), findsOneWidget);
  });

  testWidgets('with a name: change, share, release after confirming',
      (tester) async {
    final fake =
        _FakeCubeId(const CubeIdState(name: 'dima'), const CubeIdOk('x'));
    await tester.pumpWidget(app(fake, []));
    await tester.pump();
    expect(find.text('@dima'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    await tester.tap(find.text('Release'));
    await tester.pumpAndSettle();
    expect(fake.released, 0, reason: 'nothing happens before confirming');
    expect(find.textContaining('Release @dima?'), findsOneWidget);
  });
}
