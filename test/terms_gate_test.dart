import 'package:cubechat/features/moderation/data/terms_controller.dart';
import 'package:cubechat/features/moderation/presentation/terms_gate.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Never loads off Hive: returns whatever version the test asks for, and
/// `loaded` resolves on the next microtask instead of after a real box open.
/// The real-disk cases (persistence, the load-race guard) are covered
/// against a real Hive box in `terms_controller_test.dart` — kept in a
/// separate file so a real box open never has to share a test isolate with a
/// `testWidgets` pump; see that file's header comment for what mixing the two
/// did.
///
/// This fake is also what every other widget test in the suite that pumps
/// `CubechatApp` overrides `termsControllerProvider` with — otherwise the
/// gate this task adds now stands in front of screens those tests were
/// written to look straight past.
class _FakeTerms extends TermsController {
  _FakeTerms(this._accepted);

  final int _accepted;

  @override
  int build() => _accepted;
}

Widget _harness({required Widget child, List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: TermsGate(child: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('while loaded has not resolved, neither the gate nor the app shows',
      (tester) async {
    await tester.pumpWidget(
      _harness(child: const Text('the app')),
    );
    // Deliberately no pump(duration): the real box open this drives is async
    // work a single frame cannot have finished, so this is exactly the window
    // the gate is required to stay blank through.
    expect(find.text('the app'), findsNothing);
    expect(find.text('cubechat rules'), findsNothing);
  });

  testWidgets('accepted < currentTermsVersion covers the app and blocks it',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _harness(
        overrides: [termsControllerProvider.overrideWith(() => _FakeTerms(0))],
        child: TextButton(
          onPressed: () => tapped = true,
          child: const Text('the app'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('cubechat rules'), findsOneWidget);
    expect(find.text('I agree'), findsOneWidget);

    // The child is still in the tree (kept alive, not thrown away) but not
    // hit-testable: the gate is opaque and on top of it in the Stack, so a
    // tap aimed at the button underneath lands on the gate instead. Proven by
    // hitting its exact center and finding no ink response / no exception —
    // `warnIfMissed: false` because the point deliberately does not hit it.
    await tester.tap(find.text('the app'), warnIfMissed: false);
    await tester.pump();
    // The gate, being on top of the Stack, is what actually caught the tap:
    // the button underneath never saw it.
    expect(tapped, isFalse);
    expect(tester.takeException(), isNull);
    expect(find.text('cubechat rules'), findsOneWidget);

    // Hardware back does nothing: `PopScope(canPop: false)` refuses the pop,
    // so the route is never actually left and the gate is still there after.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('cubechat rules'), findsOneWidget);
  });

  testWidgets('accepted == currentTermsVersion shows the child immediately',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        overrides: [
          termsControllerProvider
              .overrideWith(() => _FakeTerms(currentTermsVersion)),
        ],
        child: const Text('the app'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('the app'), findsOneWidget);
    expect(find.text('cubechat rules'), findsNothing);
  });

  testWidgets('tapping "I agree" stores the current version and reveals the child',
      (tester) async {
    final container = ProviderContainer(
      overrides: [termsControllerProvider.overrideWith(() => _FakeTerms(0))],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TermsGate(child: Text('the app')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('cubechat rules'), findsOneWidget);

    await tester.tap(find.text('I agree'));
    await tester.pump();
    await tester.pump();

    expect(find.text('the app'), findsOneWidget);
    expect(container.read(termsControllerProvider), currentTermsVersion);
  });

  testWidgets('after reset() the gate returns', (tester) async {
    final container = ProviderContainer(
      overrides: [
        termsControllerProvider
            .overrideWith(() => _FakeTerms(currentTermsVersion)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const TermsGate(child: Text('the app')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('the app'), findsOneWidget);

    await container.read(termsControllerProvider.notifier).reset();
    await tester.pump();
    await tester.pump();

    // "the app" is still in the tree — see the "covers the app and blocks
    // it" test above for why findsNothing is the wrong check here (the gate
    // keeps the child mounted under `ExcludeSemantics`, it just covers it).
    expect(find.text('cubechat rules'), findsOneWidget);
  });
}
