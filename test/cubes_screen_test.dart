import 'package:cubechat/features/backup/data/backup_made_controller.dart';
import 'package:cubechat/features/pro/data/cubes_controller.dart';
import 'package:cubechat/features/pro/models/cube_pack.dart';
import 'package:cubechat/features/pro/presentation/cubes_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Cubes extends CubesController {
  _Cubes(this._value);
  final CubesState _value;
  @override
  CubesState build() => _value;
  @override
  Future<void> refresh() async {}
}

class _BackupMade extends BackupMadeController {
  _BackupMade(this._at);
  final DateTime? _at;
  @override
  DateTime? build() => _at;
}

Widget _app({required CubesState cubes, required DateTime? backupAt}) =>
    ProviderScope(
      overrides: [
        cubesProvider.overrideWith(() => _Cubes(cubes)),
        backupMadeProvider.overrideWith(() => _BackupMade(backupAt)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const CubesScreen(),
      ),
    );

void main() {
  setUp(() {
    // A phone-sized view, or the ladder lays out for an 800-wide screen.
  });

  testWidgets('without a backup it sells nothing and offers one instead',
      (tester) async {
    // The rule the whole screen exists for: a balance is tied to a key, a
    // reinstall makes a new key, and somebody who loses cubes that way is
    // right to ask for their money back.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        cubes: const CubesState(balance: 0, loaded: true),
        backupAt: null,
      ),
    );
    await tester.pump();

    expect(find.text('Make a backup'), findsOneWidget);
    for (final pack in CubePack.ladder) {
      expect(find.text('${pack.cubes}'), findsNothing,
          reason: 'offered ${pack.storeId} with no backup');
    }
  });

  testWidgets('with a backup the whole ladder is on offer', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        cubes: const CubesState(balance: 0, loaded: true),
        backupAt: DateTime(2026, 9, 1),
      ),
    );
    await tester.pump();

    expect(find.text('Make a backup'), findsNothing);
    expect(find.text('100'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('5000'), 200);
    expect(find.text('5000'), findsOneWidget);
  });

  testWidgets('a balance nobody has answered for shows a dash, not a zero',
      (tester) async {
    // Showing 0 to somebody who has cubes reads as "they are gone".
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(cubes: CubesState.unknown, backupAt: DateTime(2026, 9, 1)),
    );
    await tester.pump();

    expect(find.text('—'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('a known balance is shown as itself', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        cubes: const CubesState(balance: 340, loaded: true),
        backupAt: DateTime(2026, 9, 1),
      ),
    );
    await tester.pump();

    expect(find.text('340'), findsOneWidget);
  });
}
