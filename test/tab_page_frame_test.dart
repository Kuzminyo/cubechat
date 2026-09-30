import 'package:cubechat/core/widgets/scroll_hiding_island.dart';
import 'package:cubechat/core/widgets/section_switch.dart';
import 'package:cubechat/core/widgets/tab_header.dart';
import 'package:cubechat/core/widgets/tab_page_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The frame Contacts and Nearby share with Chats: a header drawn over the
/// page, a search that folds into a round button as the page scrolls, and the
/// section island that slides away under the header.
///
/// Pinned: the page starts below all three; the list moves with the finger and
/// by nothing else while the search folds; the search ends as a 42-point
/// circle in the header row; the island goes on the way down and comes back on
/// the slightest move up.
void main() {
  Future<void> pump(WidgetTester tester, {bool search = true}) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabPageFrame(
            header: const TabHeader(
              mark: Icon(Icons.star),
              title: 'Title',
              subtitle: 'Sub',
            ),
            search: search
                ? TabFrameSearch(hint: 'Search…', onTap: () {})
                : null,
            island: const SizedBox(
              key: Key('island'),
              height: SectionSwitch.height,
              child: ColoredBox(color: Colors.green),
            ),
            pageKey: 0,
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

  testWidgets('the page starts below header, search and island',
      (tester) async {
    await pump(tester);
    expect(
      tester.getTopLeft(find.text('row 0')).dy,
      TabHeader.height + TabPageFrame.searchRoom + TabPageFrame.islandHeight,
    );
    await pump(tester, search: false);
    expect(
      tester.getTopLeft(find.text('row 0')).dy,
      TabHeader.height + TabPageFrame.islandHeight,
    );
  });

  testWidgets('the search folds into a button; the list only follows the '
      'finger', (tester) async {
    await pump(tester);
    final before = tester.getTopLeft(find.text('row 3')).dy;
    final gesture = await tester.startGesture(const Offset(200, 500));
    await gesture.moveBy(const Offset(0, -40));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    final moved = before - tester.getTopLeft(find.text('row 3')).dy;
    // Touch slop eats the start of a drag; beyond that, finger and list agree.
    expect(moved, inInclusiveRange(40, 80));
    await gesture.up();
    await tester.pumpAndSettle();

    final button = tester.getRect(find.byKey(TabPageFrame.searchKey));
    expect(button.width, 42);
    expect(button.height, 42);
    expect(button.center.dy, closeTo(TabHeader.topPadding + 22, 0.5));
  });

  testWidgets('the island leaves on the way down and returns on the way up',
      (tester) async {
    await pump(tester);
    double islandBottom() =>
        tester.getBottomLeft(find.byKey(const Key('island'))).dy;

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    // Tucked under the collapsed header.
    expect(islandBottom(), lessThanOrEqualTo(TabHeader.height));

    await tester.drag(find.byType(ListView), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(
      islandBottom(),
      TabHeader.height + TabPageFrame.islandTop + SectionSwitch.height,
    );
  });
}
