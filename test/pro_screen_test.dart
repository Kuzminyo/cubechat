import 'dart:async';

import 'package:cubechat/features/pro/data/entitlement_source.dart';
import 'package:cubechat/features/pro/data/pro_controller.dart';
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:cubechat/features/pro/presentation/pro_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen is asked which half to draw, and that is what gets pinned.
/// `build()` returns the answer directly and never calls `super.build()`,
/// which would load Hive over it a frame later.
class _Pro extends ProController {
  _Pro(this._value);
  final ProState _value;
  @override
  ProState build() => _value;
}

/// `proProvider` is overridden, so nothing reads the source — but the provider
/// still has to resolve to something rather than throw.
class _IdleSource implements EntitlementSource {
  @override
  Stream<ProState> get changes => const Stream<ProState>.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> restore() async {}
  @override
  Future<void> buy(ProProduct product) async {}
  @override
  Future<void> dispose() async {}
}

Widget _app(ProState value) => ProviderScope(
      overrides: [
        entitlementSourceProvider.overrideWithValue(_IdleSource()),
        proProvider.overrideWith(() => _Pro(value)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ProScreen(),
      ),
    );

void main() {
  testWidgets('offers all three products to somebody without Pro',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(ProState.free));
    await tester.pumpAndSettle();

    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Yearly'), findsOneWidget);
    expect(find.text('Lifetime'), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
  });

  testWidgets('tells an existing subscriber that Pro is already on',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(const ProState(source: ProSource.lifetime, loaded: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pro is active on this device'), findsOneWidget);
    expect(find.text('Monthly'), findsNothing);
  });

  testWidgets('shows no padlock while the store has not answered',
      (tester) async {
    // Unknown is not free. Somebody who paid must not see the sales pitch for
    // a frame on every cold start.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // A single pump, not pumpAndSettle: the spinner never stops, so there is
    // no settled frame to wait for and pumpAndSettle times out instead.
    await tester.pumpWidget(_app(ProState.unknown));
    await tester.pump();

    expect(find.text('Monthly'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
