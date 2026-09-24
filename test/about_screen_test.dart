import 'package:cubechat/features/moderation/presentation/about_screen.dart';
import 'package:cubechat/features/moderation/presentation/legal_links.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('About provides support, rules, privacy and a general report',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: AboutScreen(),
        ),
      ),
    );

    expect(find.text('Email the developer'), findsOneWidget);
    expect(find.text('Terms of use'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    await tester.tap(find.text('Report a violation'));
    await tester.pumpAndSettle();
    expect(find.text("What's wrong?"), findsOneWidget);
    expect(find.text('Send report'), findsOneWidget);
    expect(find.textContaining('private Telegram bot'), findsOneWidget);
  });

  testWidgets('legal links follow the displayed language', (tester) async {
    late BuildContext enContext;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(builder: (context) {
        enContext = context;
        return const SizedBox();
      }),
    ));
    expect(termsDocumentUrl(enContext).path, endsWith('terms.en.md'));
    expect(
        privacyDocumentUrl(enContext).path, endsWith('privacy-policy.en.md'));

    late BuildContext ukContext;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('uk'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(builder: (context) {
        ukContext = context;
        return const SizedBox();
      }),
    ));
    expect(termsDocumentUrl(ukContext).path, endsWith('terms.uk.md'));
    expect(
        privacyDocumentUrl(ukContext).path, endsWith('privacy-policy.uk.md'));
  });
}
