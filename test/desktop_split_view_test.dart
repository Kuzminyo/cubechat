import 'package:cubechat/core/util/platform_capabilities.dart';
import 'package:cubechat/features/desktop/desktop_split_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A computer's window wider than 900 px shows the chats on the left and the
/// open chat on the right, the way Telegram Desktop does; narrower, it is the
/// phone layout.
void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required double width,
    PlatformCapabilities caps = PlatformCapabilities.desktop,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [platformCapabilitiesProvider.overrideWithValue(caps)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DesktopSplitView(
            list: Builder(
              builder: (context) =>
                  Text('list ${MediaQuery.sizeOf(context).width.round()}'),
            ),
            detailBuilder: (open, close) => TextButton(
              onPressed: close,
              child: Text('chat ${open.peerId}'),
            ),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('wide: the list and the open chat side by side', (tester) async {
    final c = await pump(tester, width: 1200);
    expect(find.text('list ${DesktopSplitView.listWidth.round()}'),
        findsOneWidget,
        reason: 'the list is laid out at its own width, not the window\'s');
    expect(
      find.byKey(const ValueKey(DesktopSplitView.emptyHint)),
      findsOneWidget,
    );
    c.read(desktopOpenChatProvider.notifier).state =
        const DesktopOpenChat(peerId: 'abc', label: 'Ann');
    await tester.pump();
    expect(find.text('chat abc'), findsOneWidget);

    await tester.tap(find.text('chat abc'));
    await tester.pump();
    expect(c.read(desktopOpenChatProvider), isNull, reason: 'back closes it');
  });

  testWidgets('narrow: just the list, at full width', (tester) async {
    final c = await pump(tester, width: 600);
    c.read(desktopOpenChatProvider.notifier).state =
        const DesktopOpenChat(peerId: 'abc', label: 'Ann');
    await tester.pump();
    expect(find.text('list 600'), findsOneWidget);
    expect(find.text('chat abc'), findsNothing);
  });

  testWidgets('a phone never splits, however wide', (tester) async {
    await pump(tester, width: 1200, caps: PlatformCapabilities.phone);
    expect(find.text('list 1200'), findsOneWidget);
  });

  testWidgets('narrowing past 900 with a chat open keeps it open',
      (tester) async {
    final c = await pump(tester, width: 1200);
    c.read(desktopOpenChatProvider.notifier).state =
        const DesktopOpenChat(peerId: 'abc', label: 'Ann');
    await tester.pump();
    tester.view.physicalSize = const Size(600, 800);
    await tester.pump();
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    expect(find.text('chat abc'), findsOneWidget);
  });
}
