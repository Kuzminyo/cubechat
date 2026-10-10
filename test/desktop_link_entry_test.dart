import 'package:cubechat/core/util/platform_capabilities.dart';
import 'package:cubechat/features/onboarding/presentation/onboarding_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A computer can start as a copy of the phone's account; a phone is the one
/// that hands an account over, so it never offers to receive one this way.
void main() {
  final t = AppLocalizationsEn();

  Future<void> pump(WidgetTester tester, PlatformCapabilities caps) async {
    SharedPreferences.setMockInitialValues({});
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [platformCapabilitiesProvider.overrideWithValue(caps)],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OnboardingScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a computer is offered the phone\'s account', (tester) async {
    await pump(tester, PlatformCapabilities.desktop);
    expect(find.text(t.desktopLinkSignIn), findsOneWidget);
  });

  testWidgets('a phone is not', (tester) async {
    await pump(tester, PlatformCapabilities.phone);
    expect(find.text(t.desktopLinkSignIn), findsNothing);
  });
}
