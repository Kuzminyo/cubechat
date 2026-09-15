import 'package:cubechat/core/routing/page_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The page underneath a slide is drawn from a snapshot while the slide runs,
/// and live the rest of the time. See `_StillWhileCovered` in
/// `page_transitions.dart`.
void main() {
  /// Whether whatever shows [text] is currently being drawn from a snapshot.
  /// Null when nothing above it can snapshot at all.
  bool? snapshotted(WidgetTester tester, String text) {
    final above = find.ancestor(
      of: find.text(text, skipOffstage: false),
      matching: find.byType(SnapshotWidget),
    );
    if (above.evaluate().isEmpty) return null;
    return tester
        .widgetList<SnapshotWidget>(above)
        .any((w) => w.controller.allowSnapshotting);
  }

  Future<NavigatorState> pumpApp(WidgetTester tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        // The shell is a Material page, as go_router makes it.
        home: const Scaffold(body: Text('list')),
      ),
    );
    return key.currentState!;
  }

  testWidgets('the tabs under an arriving screen are a snapshot until it lands',
      (tester) async {
    final navigator = await pumpApp(tester);
    expect(snapshotted(tester, 'list'), isNot(isTrue));

    navigator.push(screenRoute<void>((_) => const Text('chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(snapshotted(tester, 'list'), isTrue);
    expect(snapshotted(tester, 'chat'), isNot(isTrue),
        reason: 'the arriving page is still settling and is drawn live');

    await tester.pumpAndSettle();
    expect(snapshotted(tester, 'list'), isNot(isTrue));

    // And on the way back, from the first frame of the close.
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(snapshotted(tester, 'list'), isTrue);

    await tester.pumpAndSettle();
    expect(find.text('chat'), findsNothing);
    expect(snapshotted(tester, 'list'), isNot(isTrue));
  });

  testWidgets('a screen under another slide is a snapshot too', (tester) async {
    final navigator = await pumpApp(tester);
    navigator.push(screenRoute<void>((_) => const Text('chat')));
    await tester.pumpAndSettle();
    expect(snapshotted(tester, 'chat'), isFalse);

    navigator.push(screenRoute<void>((_) => const Text('profile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(snapshotted(tester, 'chat'), isTrue);
    expect(snapshotted(tester, 'profile'), isFalse);

    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(snapshotted(tester, 'chat'), isFalse);
    expect(find.text('chat'), findsOneWidget);
  });

  testWidgets('nothing is snapshotted under a photo opening over it',
      (tester) async {
    // A photo flies out of its bubble into the viewer. A snapshot taken as the
    // viewer arrives would still hold the photo in the bubble, and show it
    // twice for the length of the flight.
    final navigator = await pumpApp(tester);
    navigator.push(screenRoute<void>((_) => const Text('chat')));
    await tester.pumpAndSettle();

    navigator.push(mediaRoute<void>((_) => const Text('photo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(snapshotted(tester, 'chat'), isFalse);
    await tester.pumpAndSettle();
  });
}
