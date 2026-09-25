import 'package:cubechat/features/moderation/data/report_client.dart';
import 'package:cubechat/features/moderation/domain/report.dart';
import 'package:cubechat/features/moderation/presentation/about_screen.dart';
import 'package:cubechat/features/moderation/presentation/legal_links.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends ReportClient {
  _Client(Ref ref) : super(ref: ref);

  final sent = <ModerationReport>[];

  @override
  Future<bool> send(ModerationReport report) async {
    sent.add(report);
    return true;
  }
}

void main() {
  testWidgets('About provides support, rules, privacy and a general report',
      (tester) async {
    late _Client client;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reportClientProvider.overrideWith((ref) => client = _Client(ref)),
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
          home: AboutScreen(),
        ),
      ),
    );

    expect(find.text('Email the developer'), findsOneWidget);
    expect(find.text('cubechatble@gmail.com'), findsOneWidget);
    expect(find.text('Terms of use'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    await tester.tap(find.text('Report a violation'));
    await tester.pumpAndSettle();
    expect(find.text("What's wrong?"), findsOneWidget);
    expect(find.textContaining('private Telegram bot'), findsOneWidget);

    await tester.tap(find.text('Send report'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(client.sent.single.toJson(), {
      'reason': 'spam',
      'context': 'general',
    });
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
