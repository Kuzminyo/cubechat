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

  group('a branch with pages of its own', () {
    /// The chats list has folders under its title, and flipping those is meant
    /// to be the same gesture as changing tab: the folders first, the next tab
    /// once they run out.
    Future<void> pumpWithFolders(
      WidgetTester tester, {
      required int folders,
      required void Function(int delta) onStep,
      required void Function(int tab) onSwitch,
    }) {
      var index = 0;
      var folder = 0;
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
                branchWantsStep: (delta) {
                  if (index != 0) return false;
                  final next = folder + delta;
                  return next >= 0 && next < folders;
                },
                onBranchStep: (delta) {
                  onStep(delta);
                  setState(() => folder += delta);
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

    testWidgets('takes the flick before the strip does', (tester) async {
      var stepped = 0;
      var switched = -1;
      await pumpWithFolders(
        tester,
        folders: 3,
        onStep: (d) => stepped += d,
        onSwitch: (i) => switched = i,
      );

      await tester.fling(find.text('one'), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();

      expect(stepped, 1, reason: 'the folder moved');
      expect(switched, -1, reason: 'and the tab did not');
      expect(_onScreen(), ['one'],
          reason: 'the strip never left, so nothing slid and snapped back');
    });

    testWidgets('gives the strip the flick that runs off the end',
        (tester) async {
      var switched = -1;
      // One folder is no folders to flip: the first flick is already the edge.
      await pumpWithFolders(
        tester,
        folders: 1,
        onStep: (_) {},
        onSwitch: (i) => switched = i,
      );

      await tester.fling(find.text('one'), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();

      expect(switched, 1);
      expect(_onScreen(), ['two']);
    });

    testWidgets('leaves every other tab alone', (tester) async {
      // The shell keeps every branch mounted, so the chats list is alive and
      // registered while somebody is two tabs away. Its folders must not eat
      // the flick there.
      var switched = -1;
      await pumpWithFolders(
        tester,
        folders: 3,
        onStep: (_) => fail('a folder stepped on the wrong tab'),
        onSwitch: (i) => switched = i,
      );
      _chooseTab(1);
      await tester.pumpAndSettle();

      await tester.fling(find.text('two'), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();

      expect(switched, 2);
    });
  });
}
