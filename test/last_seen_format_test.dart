import 'package:cubechat/core/utils/time_format.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// How long ago somebody was last in the app, said the way a person says it.
///
/// Three registers, and the boundaries between them are the whole feature:
/// under a minute nobody says "one minute ago", inside the hour the number is
/// what decides whether you wait, and past that the elapsed time stops being a
/// useful form — "214 minutes ago" is arithmetic somebody has to do.
Future<String> _label(WidgetTester tester, DateTime at) async {
  late String out;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          out = formatLastSeen(context, at);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return out;
}

void main() {
  // Deliberately not sitting on the boundaries. The formatter reads its own
  // clock, so a case written at 59 seconds becomes a case at 60 the moment the
  // suite is a second slower than it was — which is what happened, on the full
  // run and never on the file alone.
  testWidgets('under a minute is "just now"', (tester) async {
    final now = DateTime.now();
    expect(await _label(tester, now), 'just now');
    expect(
      await _label(tester, now.subtract(const Duration(seconds: 30))),
      'just now',
    );
  });

  testWidgets('a clock that has run backwards is still "just now"',
      (tester) async {
    // Two phones do not agree to the second, and a stamp a few seconds in the
    // future must not come out as a negative count.
    final ahead = DateTime.now().add(const Duration(seconds: 20));
    expect(await _label(tester, ahead), 'just now');
  });

  testWidgets('inside the hour it counts minutes', (tester) async {
    final now = DateTime.now();
    expect(
      await _label(tester, now.subtract(const Duration(minutes: 1))),
      '1 minute ago',
    );
    expect(
      await _label(tester, now.subtract(const Duration(minutes: 12))),
      '12 minutes ago',
    );
    expect(
      await _label(tester, now.subtract(const Duration(minutes: 45))),
      '45 minutes ago',
    );
  });

  testWidgets('past an hour it is the clock, not a count', (tester) async {
    final now = DateTime.now();
    final anHourAgo = now.subtract(const Duration(minutes: 61));
    final label = await _label(tester, anHourAgo);

    expect(label, isNot(contains('minute')));
    // Same day, so the chat-list format gives the wall clock. Compared against
    // the same formatter rather than a hardcoded string: what "16:00" looks
    // like is the locale's business, and pinning it here would pin the locale.
    expect(label, contains(':'));
  });
}
