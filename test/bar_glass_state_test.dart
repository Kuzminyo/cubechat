import 'package:cubechat/core/util/ui_activity.dart';
import 'package:cubechat/core/widgets/bar_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts how many times it was built from scratch, so a test can tell a
/// rebuild (cheap, expected) from a remount (which throws away State).
class _Probe extends StatefulWidget {
  const _Probe();

  static int mounts = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 100, height: 100);
}

void main() {
  setUp(() {
    _Probe.mounts = 0;
    UiActivity.instance.setScrolling(false);
  });

  tearDown(() => UiActivity.instance.setScrolling(false));

  testWidgets('the pane keeps its content mounted when scrolling starts',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BarGlass(child: _Probe()))),
    );
    expect(_Probe.mounts, 1);

    // What a scroll view inside the pane does on the first frame of a drag.
    UiActivity.instance.setScrolling(true);
    await tester.pump();
    expect(
      _Probe.mounts,
      1,
      reason: 'dropping the blur must not rebuild the pane from scratch',
    );

    UiActivity.instance.setScrolling(false);
    await tester.pump();
    expect(_Probe.mounts, 1);
  });

  testWidgets('a list inside the pane scrolls while it reports scrolling',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    // The media picker sheet's arrangement: a scroll view inside the pane that
    // flips the app-wide scrolling signal the pane itself listens to.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BarGlass(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification) {
                  UiActivity.instance.setScrolling(true);
                } else if (n is ScrollEndNotification) {
                  UiActivity.instance.setScrolling(false);
                }
                return false;
              },
              child: ListView.builder(
                controller: controller,
                itemCount: 200,
                itemBuilder: (_, i) => SizedBox(height: 60, child: Text('$i')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      greaterThan(0),
      reason: 'the drag must move the list, not remount it at the top',
    );
  });
}
