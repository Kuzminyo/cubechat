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

  testWidgets('past an hour it counts hours', (tester) async {
    final now = DateTime.now();
    expect(
      await _label(tester, now.subtract(const Duration(minutes: 61))),
      '1 hour ago',
    );
    expect(
      await _label(tester, now.subtract(const Duration(hours: 5))),
      '5 hours ago',
    );
  });

  testWidgets('yesterday keeps the hour', (tester) async {
    // Reachable past the 24-hour rule: seen at half past midnight and read
    // late the following night is forty-six hours by the clock and yesterday
    // by the calendar, and the calendar is what a person means.
    // Yesterday at midnight: always at least twenty-four hours back, whatever
    // the time of day is when this runs, and always calendar-yesterday. Picked
    // that way because the first attempt used yesterday at 22:00, which is
    // twenty-two hours ago and correctly comes out as hours.
    final now = DateTime.now();
    final yesterday =
        DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
    final label = await _label(tester, yesterday);

    expect(label, startsWith('yesterday at'));
    expect(label, contains(':'));
  });

  testWidgets('this week is the day, spelled out', (tester) async {
    // Not the abbreviation the chat row uses. "Thu" beside a name is all a row
    // has space for; in a sentence about a person it reads as a stray letter,
    // which is how it was reported.
    final label =
        await _label(tester, DateTime.now().subtract(const Duration(days: 3)));

    expect(label, startsWith('on '));
    expect(label.length, greaterThan(5));
  });

  testWidgets('past a week it counts weeks, then months', (tester) async {
    final now = DateTime.now();
    expect(
      await _label(tester, now.subtract(const Duration(days: 8))),
      'a week ago',
    );
    expect(
      await _label(tester, now.subtract(const Duration(days: 20))),
      '2 weeks ago',
    );
    expect(
      await _label(tester, now.subtract(const Duration(days: 40))),
      'a month ago',
    );
    expect(
      await _label(tester, now.subtract(const Duration(days: 200))),
      '6 months ago',
    );
  });

  testWidgets('past a year it stops counting', (tester) async {
    // A number nobody holds. "was 14 months ago" is arithmetic again, and by
    // then the only honest thing left to say is that it was a long time.
    expect(
      await _label(tester, DateTime.now().subtract(const Duration(days: 500))),
      'a long time ago',
    );
  });
}
