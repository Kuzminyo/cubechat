import 'package:cubechat/core/widgets/scroll_hiding_island.dart';
import 'package:cubechat/core/widgets/section_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The section island (Nearby | AirDrop | Files) gets out of the way while
/// you read and comes back the moment you head back up.
///
/// It floats over the list rather than taking a slot above it: collapsing a
/// slot would pull the list up by the island's height mid-scroll, which is the
/// kind of jump this work exists to remove. What is pinned: the list starts
/// below the island, the island leaves on the way down, returns on the
/// slightest move up, and the list itself never shifts when it does.
void main() {
  const islandHeight = 80.0;

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScrollHidingIsland(
            islandHeight: islandHeight,
            island: const SizedBox(
              key: Key('island'),
              height: islandHeight,
              child: ColoredBox(color: Colors.green),
            ),
            child: Builder(
              builder: (context) => ListView(
                padding: EdgeInsets.only(top: IslandInset.of(context)),
                children: [
                  for (var i = 0; i < 60; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double islandTop(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(const Key('island'))).dy;

  testWidgets('the list starts below the island', (tester) async {
    await pump(tester);
    expect(tester.getTopLeft(find.text('row 0')).dy, islandHeight);
    expect(islandTop(tester), 0);
  });

  testWidgets('down hides it, the slightest move up brings it back',
      (tester) async {
    await pump(tester);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(islandTop(tester), lessThanOrEqualTo(-islandHeight));

    final rowBefore = tester.getTopLeft(find.text('row 10')).dy;
    // A small pull back: past touch slop, and not much more.
    await tester.drag(find.byType(ListView), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(islandTop(tester), 0);
    // The list moved by the finger's travel and nothing else — the island
    // arriving did not push it.
    final moved = tester.getTopLeft(find.text('row 10')).dy - rowBefore;
    expect(moved, lessThanOrEqualTo(30));
  });

  testWidgets('the section switch is a capsule with a concentric pill',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SectionSwitch(
              labels: const ['A', 'B', 'C'],
              selected: 0,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    final height = tester.getSize(find.byType(SectionSwitch)).height;
    expect(SectionSwitch.outerRadius, height / 2);
    expect(
      SectionSwitch.pillRadius,
      SectionSwitch.outerRadius - SectionSwitch.inset,
    );
  });
}
