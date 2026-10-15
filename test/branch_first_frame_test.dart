import 'package:cubechat/core/routing/branch_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cold start's first frame builds the tab on screen and nothing else.
///
/// 1165 on a Galaxy S24+ (2026-10-15): 1253 ms from the process starting to
/// the first frame, 430 of them after the router's first page, while that frame
/// built Chats, Contacts and the profile together. See `_built` in
/// branch_container.dart.
void main() {
  Widget shell(List<String> names, {int current = 0}) => MaterialApp(
        home: BranchContainer(
          currentIndex: current,
          branches: [for (final n in names) Text(n)],
          onSwitch: (_) {},
        ),
      );

  testWidgets('the first frame builds only the tab on screen', (tester) async {
    await tester.pumpWidget(shell(['chats', 'contacts', 'profile']));
    expect(find.text('chats'), findsOneWidget);
    expect(find.text('contacts', skipOffstage: false), findsNothing);
    expect(find.text('profile', skipOffstage: false), findsNothing);

    // Then one more per frame.
    await tester.pump();
    expect(find.text('contacts', skipOffstage: false), findsOneWidget);
    expect(find.text('profile', skipOffstage: false), findsNothing);
    await tester.pump();
    expect(find.text('profile', skipOffstage: false), findsOneWidget);
  });

  testWidgets('a tab asked for before its turn is built at once',
      (tester) async {
    await tester.pumpWidget(shell(['chats', 'contacts', 'profile']));
    await tester.pumpWidget(shell(['chats', 'contacts', 'profile'], current: 2));
    expect(find.text('profile', skipOffstage: false), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('profile'), findsOneWidget);
    expect(find.text('contacts', skipOffstage: false), findsOneWidget,
        reason: 'and the rest still arrive');
  });
}
