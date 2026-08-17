import 'package:cubechat/core/utils/time_format.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads a day label the way the conversation does.
Future<String> _label(WidgetTester tester, DateTime day, String locale) async {
  late String result;
  await tester.pumpWidget(MaterialApp(
    // Cupertino's delegate too: without it a Ukrainian locale raises a warning
    // that the widgets library turns into a test failure.
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: Locale(locale),
    home: Builder(
      builder: (context) {
        result = formatDayHeader(context, day);
        return const SizedBox.shrink();
      },
    ),
  ));
  return result;
}

void main() {
  group('where a separator goes', () {
    final monday = DateTime(2026, 8, 17, 9, 0);

    test('the very first message always opens a day', () {
      expect(startsNewDay(monday, null), isTrue);
    });

    test('two messages on the same day get one separator between them', () {
      expect(
        startsNewDay(DateTime(2026, 8, 17, 23, 59), monday),
        isFalse,
        reason: 'fourteen hours later is still Monday',
      );
    });

    test('a boundary is a calendar one, not a number of hours', () {
      // Forty minutes apart and on different days. Counting elapsed time would
      // put no separator here, and this is exactly the boundary a reader
      // scrolling back is looking for.
      expect(
        startsNewDay(
          DateTime(2026, 8, 18, 0, 10),
          DateTime(2026, 8, 17, 23, 30),
        ),
        isTrue,
      );
    });

    test('a long silence within one day does not open a new one', () {
      expect(
        startsNewDay(
          DateTime(2026, 8, 17, 23, 30),
          DateTime(2026, 8, 17, 0, 10),
        ),
        isFalse,
      );
    });
  });

  group('what the separator says', () {
    testWidgets('today and yesterday get their names', (tester) async {
      final now = DateTime.now();
      expect(await _label(tester, now, 'en'), 'Today');
      expect(
        await _label(tester, now.subtract(const Duration(days: 1)), 'en'),
        'Yesterday',
      );
    });

    testWidgets('this year drops the year, an older one keeps it',
        (tester) async {
      final now = DateTime.now();
      // Far enough back not to be today or yesterday, and safely inside the
      // same year whatever today's date is.
      final thisYear = DateTime(now.year, 1, 14);
      final older = DateTime(now.year - 2, 1, 14);

      final recent = await _label(tester, thisYear, 'en');
      final ancient = await _label(tester, older, 'en');

      expect(recent, isNot(contains('${now.year}')),
          reason: 'a conversation is almost all this year — saying so on every '
              'separator is noise');
      expect(ancient, contains('${now.year - 2}'),
          reason: 'the year is the interesting part of an old date');
    });

    testWidgets('it follows the interface language', (tester) async {
      final now = DateTime.now();
      expect(await _label(tester, now, 'uk'), isNot('Today'));
    });
  });
}
