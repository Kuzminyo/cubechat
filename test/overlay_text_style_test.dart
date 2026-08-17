import 'package:cubechat/core/widgets/glass_toast.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text with nowhere to get its style from.
///
/// Flutter's fallback style is black with a **yellow double underline** — the
/// framework saying "nothing told me how to draw this". Anything mounted
/// straight into an overlay or pushed as a bare route has no Scaffold and no
/// Material above it, so every label in it was drawn that way. The toast was
/// underlined on every screen it appeared on.
void main() {
  testWidgets('a toast has a Material to take its style from', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          ctx = context;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ));

    showGlassToast(ctx, 'turn the map on first', tone: ToastTone.danger);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('turn the map on first'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('turn the map on first'),
        matching: find.byType(Material),
      ),
      findsWidgets,
      reason: 'without one the toast is drawn with the yellow debug underline',
    );

    // Let the entry take itself down, so the test does not end with a pending
    // timer holding an overlay open.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
  });
}
