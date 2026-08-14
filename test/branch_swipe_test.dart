import 'package:cubechat/core/routing/branch_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Moves the tab from outside the container, the way the bar does.
late ValueChanged<int> _chooseTab;

/// Which branches are on screen. A settled strip shows exactly one; a strip
/// caught between two tabs shows both, which is the state being tested for.
List<String> _onScreen() => [
      for (final label in ['one', 'two', 'three'])
        if (find.text(label).evaluate().isNotEmpty) label,
    ];

Future<void> _pumpShell(WidgetTester tester, ValueChanged<int> onSwitch) {
  var index = 0;
  return tester.pumpWidget(
    MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          _chooseTab = (i) => setState(() => index = i);
          return BranchContainer(
            currentIndex: index,
            onSwitch: (i) {
              onSwitch(i);
              setState(() => index = i);
            },
            branches: const [
              Center(child: Text('one')),
              Center(child: Text('two')),
              Center(child: Text('three')),
            ],
          );
        },
      ),
    ),
  );
}

void main() {
  testWidgets('a drag the system takes away still lands on a tab',
      (tester) async {
    var switched = -1;
    await _pumpShell(tester, (i) => switched = i);
    expect(_onScreen(), ['one']);

    // Past the halfway line, then the gesture is taken from us — which is what
    // the system's own edge swipe does to it.
    final gesture = await tester.startGesture(const Offset(600, 400));
    await gesture.moveBy(const Offset(-500, 0));
    await tester.pump();
    expect(_onScreen(), ['one', 'two'], reason: 'mid-drag, both are showing');

    await gesture.cancel();
    await tester.pumpAndSettle();

    // Landed, rather than left hanging between two screens.
    expect(_onScreen(), ['two']);
    expect(switched, 1);
  });

  testWidgets('a strip left mid-drag is rescued by choosing a tab',
      (tester) async {
    var switched = -1;
    await _pumpShell(tester, (i) => switched = i);

    // A drag that never ends: the finger stays down. This is the state the
    // shell was found wedged in — and while it lasted, every tap on the bar
    // was ignored, because the flag that says "a drag is in progress" was also
    // what stopped the strip from catching up.
    final stuck = await tester.startGesture(const Offset(600, 400));
    await stuck.moveBy(const Offset(-300, 0));
    await tester.pump();
    expect(_onScreen(), ['one', 'two']);

    // Somebody taps a tab. That is now enough to land the strip.
    _chooseTab(2);
    await tester.pumpAndSettle();

    expect(_onScreen(), ['three']);
    expect(switched, -1, reason: 'the bar moved the tab, not a drag');
    await stuck.up();
  });

  testWidgets('an ordinary swipe still settles on the next tab',
      (tester) async {
    var switched = -1;
    await _pumpShell(tester, (i) => switched = i);

    await tester.fling(find.text('one'), const Offset(-400, 0), 1200);
    await tester.pumpAndSettle();

    expect(_onScreen(), ['two']);
    expect(switched, 1);
  });
}
