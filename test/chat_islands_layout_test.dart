import 'package:cubechat/features/chat/presentation/widgets/chat_islands_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The newest message clears the composer on the very frame the composer
/// changes height — a reply bar appearing, a sent draft emptying it.
///
/// Measured after each frame and applied with a setState, the list's padding
/// was always one frame behind the composer, so every change of height was
/// drawn once with the newest message under the composer (or a gap over it)
/// and then snapped: "everything jumps — sending, the keyboard, replying"
/// (2026-10-15).
void main() {
  testWidgets('a taller composer moves the conversation on the same frame',
      (tester) async {
    final composerHeight = ValueNotifier<double>(70);
    addTearDown(composerHeight.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatIslandsLayout(
          header: const SizedBox(height: 100),
          list: ListView.builder(
            reverse: true,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: 40,
            itemBuilder: (_, i) => SizedBox(height: 50, child: Text('m$i')),
          ),
          composer: ValueListenableBuilder<double>(
            valueListenable: composerHeight,
            builder: (_, h, __) =>
                SizedBox(key: const Key('composer'), height: h),
          ),
        ),
      ),
    );

    double gap() =>
        tester.getTopLeft(find.byKey(const Key('composer'))).dy -
        tester.getBottomLeft(find.text('m0')).dy;
    expect(gap(), 12);

    // The reply bar arrives: one frame, no settling.
    composerHeight.value = 130;
    await tester.pump();
    expect(gap(), 12, reason: 'the newest message slid under the composer');

    // The draft is sent and the composer shrinks back.
    composerHeight.value = 70;
    await tester.pump();
    expect(gap(), 12, reason: 'a gap opened over the composer');
  });

  testWidgets('the header keeps its own height and the list starts below it',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatIslandsLayout(
          // A column, as the real header is: under a height bound it would
          // stretch to fill the screen and leave the list no room at all.
          header: const Column(children: [SizedBox(height: 90)]),
          list: const SizedBox.expand(key: Key('list')),
          composer: const SizedBox(height: 60),
        ),
      ),
    );
    expect(tester.getTopLeft(find.byKey(const Key('list'))).dy, 90);
    expect(tester.getSize(find.byKey(const Key('list'))).height, 600 - 90 - 60);
  });
}
