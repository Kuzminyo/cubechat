import 'package:cubechat/core/routing/branch_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two branches, the first of which owns a text field — the shape that matters,
/// because the Contacts tab is exactly this and it is the one tab root in the
/// app with a keyboard of its own.
Widget _shell({required int index, required ValueChanged<int> onSwitch}) {
  return MaterialApp(
    home: Scaffold(
      body: BranchContainer(
        currentIndex: index,
        onSwitch: onSwitch,
        branches: const [
          Align(
            alignment: Alignment.topCenter,
            child: TextField(key: Key('search')),
          ),
          Center(child: Text('another tab')),
        ],
      ),
    ),
  );
}

void main() {
  group('leaving a tab', () {
    // Branches stay mounted for the life of the shell, which is what makes tab
    // switching free — and what made this bug. Offstage does not touch focus,
    // so a field left focused in one tab kept the platform keyboard open over
    // whatever tab arrived next. On iOS there was then no way to close it: the
    // field still holding focus was offstage and behind an IgnorePointer, so
    // there was nothing left on screen to tap, and the platform offers no
    // dismissal of its own.
    //
    // `testTextInput.isVisible` is the assertion that matches the complaint:
    // not "which node holds focus" but "is the keyboard up", which is the only
    // part of this the user could see.
    testWidgets('puts the keyboard away when the tab is switched',
        (tester) async {
      var index = 0;
      await tester.pumpWidget(_shell(index: index, onSwitch: (i) => index = i));

      await tester.tap(find.byKey(const Key('search')));
      await tester.pumpAndSettle();
      expect(
        tester.testTextInput.isVisible,
        isTrue,
        reason: 'tapping the field is what raises the keyboard',
      );

      await tester.pumpWidget(_shell(index: 1, onSwitch: (i) => index = i));
      await tester.pumpAndSettle();

      expect(
        tester.testTextInput.isVisible,
        isFalse,
        reason: 'the field in the tab we left must not still hold the '
            'keyboard open over the tab we arrived at',
      );
    });

    testWidgets('puts the keyboard away as the drag between tabs starts',
        (tester) async {
      var index = 0;
      await tester.pumpWidget(_shell(index: index, onSwitch: (i) => index = i));

      await tester.tap(find.byKey(const Key('search')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);

      // Not a full swipe, and deliberately started away from the field: the
      // point is that the keyboard goes as the strip starts moving, so the tab
      // sliding in is uncovered while it travels rather than arriving behind
      // somebody else's keyboard.
      final gesture = await tester.startGesture(const Offset(400, 500));
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('leaves the keyboard alone while the tab stays put',
        (tester) async {
      var index = 0;
      await tester.pumpWidget(_shell(index: index, onSwitch: (i) => index = i));

      await tester.tap(find.byKey(const Key('search')));
      await tester.pumpAndSettle();

      // A rebuild that does not move the strip — a provider ticking somewhere
      // above, which happens constantly in this app — must not cost the user
      // the keyboard they are typing on.
      await tester.pumpWidget(_shell(index: 0, onSwitch: (i) => index = i));
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isTrue);
    });
  });
}
