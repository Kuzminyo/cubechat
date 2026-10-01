import 'package:cubechat/core/widgets/glass_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Чекають на відправку", opened from the Chats tab, came up under the
/// floating nav bar: a tab has its own navigator, the bar sits above it, and
/// a sheet on that navigator is drawn below the bar.
void main() {
  testWidgets('a sheet opened inside a tab covers the nav bar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late BuildContext tabContext;
    var barTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // The tab's own navigator, as a StatefulShellRoute branch has.
              Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (context) {
                    tabContext = context;
                    return const SizedBox.expand();
                  },
                ),
              ),
              // The floating bar, above the tab.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 90,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => barTaps++,
                  child: const ColoredBox(
                    key: Key('bar'),
                    color: Colors.green,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    showGlassSheet<void>(
      context: tabContext,
      builder: (_) => const SizedBox(height: 300, child: Text('sheet')),
    );
    await tester.pumpAndSettle();

    // A tap where the bar is lands on the sheet, not on the bar under it.
    await tester.tapAt(const Offset(195, 800));
    await tester.pumpAndSettle();
    expect(barTaps, 0);
  });
}
