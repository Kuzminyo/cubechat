import 'package:cubechat/features/profile/presentation/settings/settings_section_icons.dart';
import 'package:cubechat/features/profile/presentation/settings/settings_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tiles every profile section is built from. What is pinned here is what
/// a person notices when it goes wrong: a long @name must not push the chevron
/// off the row, and a tap must reach the row that was tapped.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }

  testWidgets('a group of rows: titles, one divider, taps land', (tester) async {
    var tapped = 0;
    await pump(
      tester,
      SettingsGroup(
        children: [
          SettingsSectionRow(
            section: SettingsSection.cubeId,
            title: 'Cube ID',
            value: '@a_very_long_name_that_will_not_fit_anywhere_on_a_phone',
            onTap: () => tapped++,
          ),
          SettingsSectionRow(
            section: SettingsSection.privacy,
            title: 'Конфіденційність і безпека',
            value: 'Через запит',
            onTap: () {},
          ),
        ],
      ),
    );

    expect(find.text('Cube ID'), findsOneWidget);
    expect(find.text('Конфіденційність і безпека'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final value = tester.widget<Text>(
      find.text('@a_very_long_name_that_will_not_fit_anywhere_on_a_phone'),
    );
    expect(value.maxLines, 1);
    expect(value.overflow, TextOverflow.ellipsis);

    expect(find.byType(SettingsGroupDivider), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(2));

    await tester.tap(find.text('Cube ID'));
    expect(tapped, 1);
  });

  testWidgets('three rows: two dividers, no duplicate-key error',
      (tester) async {
    await pump(
      tester,
      SettingsGroup(
        children: [
          for (final s in [
            SettingsSection.chats,
            SettingsSection.appearance,
            SettingsSection.data,
          ])
            SettingsSectionRow(section: s, title: s.name, onTap: () {}),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SettingsGroupDivider), findsNWidgets(2));
  });

  testWidgets('a danger row has no chevron', (tester) async {
    await pump(
      tester,
      SettingsGroup(
        children: [
          SettingsSectionRow(
            section: SettingsSection.about,
            title: 'Про застосунок',
            value: '1.0.0',
            onTap: () {},
          ),
          SettingsSectionRow(
            section: SettingsSection.wipe,
            title: 'Екстрене стирання',
            danger: true,
            onTap: () {},
          ),
        ],
      ),
    );
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a section screen: subheader in capitals, back button',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const SettingsSectionScaffold(
          title: 'Зв\'язок',
          children: [SettingsSubheader('Хто мене бачить')],
        ),
      ),
    );
    expect(find.text('Зв\'язок'), findsOneWidget);
    expect(find.text('ХТО МЕНЕ БАЧИТЬ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
