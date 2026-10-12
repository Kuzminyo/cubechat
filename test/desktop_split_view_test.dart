import 'package:cubechat/core/util/platform_capabilities.dart';
import 'package:cubechat/features/chats/data/chat_folders_controller.dart';
import 'package:cubechat/features/chats/data/user_chat_folders_controller.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/desktop/desktop_rail.dart';
import 'package:cubechat/features/desktop/desktop_split_view.dart';
import 'package:cubechat/features/profile/data/nav_bar_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoFolders extends ChatFoldersController {
  @override
  List<ChatFolder> build() => const [];
}

class _Bar extends NavBarController {
  @override
  NavBarLayout build() => const NavBarLayout([
        NavDestination.chats,
        NavDestination.contacts,
        NavDestination.profile,
      ]);
}

class _NoUserFolders extends UserChatFoldersController {
  @override
  List<UserChatFolder> build() => const [];
}

/// A computer window laid out the way Telegram Desktop lays one out: the rail,
/// the chat list, and the open chat; a column of faces when narrower; the
/// phone's layout when narrower still, and always on a phone.
void main() {
  final t = AppLocalizationsEn();

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required double width,
    PlatformCapabilities caps = PlatformCapabilities.desktop,
    int branch = 0,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        platformCapabilitiesProvider.overrideWithValue(caps),
        chatFoldersControllerProvider.overrideWith(_NoFolders.new),
        userChatFoldersControllerProvider.overrideWith(_NoUserFolders.new),
        visibleChatsProvider.overrideWithValue(const []),
        navBarControllerProvider.overrideWith(_Bar.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DesktopSplitView(
            currentBranch: branch,
            list: Builder(
              builder: (context) => Text(
                'list ${MediaQuery.sizeOf(context).width.round()}'
                '${DesktopChrome.railShown(context) ? ' rail' : ''}',
              ),
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

  double columnWidth(WidgetTester tester) => tester
      .getSize(
        find
            .ancestor(
              of: find.textContaining('list'),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      )
      .width;

  testWidgets('wide: rail, list and the open chat side by side',
      (tester) async {
    final c = await pump(tester, width: 1200);
    expect(
      find.text('list ${DesktopSplitView.listWidth.round()} rail'),
      findsOneWidget,
      reason: 'the list is laid out at its own width and knows the rail is '
          'there, so it leaves out the bottom bar and folder row',
    );
    expect(find.text(t.navChats), findsOneWidget, reason: 'the bar, upright');
    expect(find.text(t.navContacts), findsOneWidget);
    expect(find.text(t.desktopPickChat), findsOneWidget);
    c.read(desktopOpenChatProvider.notifier).state =
        const DesktopOpenChat(peerId: 'abc', label: 'Ann');
    await tester.pump();
    expect(find.text('chat abc'), findsOneWidget);

    await tester.tap(find.text('chat abc'));
    await tester.pump();
    expect(c.read(desktopOpenChatProvider), isNull, reason: 'back closes it');
  });

  testWidgets('the empty pane\'s hint sits in the middle of the pane',
      (tester) async {
    await pump(tester, width: 1200);
    final pill =
        tester.getCenter(find.byKey(const ValueKey(DesktopSplitView.emptyHint)));
    const paneLeft = 76 + DesktopSplitView.listWidth + 1;
    expect(pill.dx, closeTo(paneLeft + (1200 - paneLeft) / 2, 1));
    expect(pill.dy, closeTo(400, 1));
  });

  testWidgets('the list folds down to faces and back', (tester) async {
    final c = await pump(tester, width: 1200);
    await tester.tap(find.byTooltip(t.desktopListCollapse));
    await tester.pumpAndSettle();
    expect(columnWidth(tester), DesktopSplitView.compactWidth);
    expect(c.read(desktopListCollapsedProvider), isTrue);
    expect(
      find.textContaining('list'),
      findsOneWidget,
      reason: 'the shell stays mounted under the faces, so the tabs keep '
          'their place',
    );
    await tester.tap(find.byTooltip(t.desktopListExpand));
    await tester.pumpAndSettle();
    expect(columnWidth(tester), DesktopSplitView.listWidth);
    expect(
      find.text('list ${DesktopSplitView.listWidth.round()} rail'),
      findsOneWidget,
    );
  });

  testWidgets('middling: faces instead of the list on Chats', (tester) async {
    await pump(tester, width: 760);
    await tester.pumpAndSettle();
    expect(columnWidth(tester), DesktopSplitView.compactWidth);
    expect(find.text(t.desktopPickChat), findsOneWidget);
  });

  group('the divider', () {
    // Asked for on 2026-10-11 against a 900 px window showing faces: "сделать
    // что бы перегородку можно было тянуть".
    Finder handle() => find.byKey(const ValueKey(DesktopSplitView.dividerKey));

    testWidgets('dragging it widens and narrows the list', (tester) async {
      final c = await pump(tester, width: 1200);
      await tester.drag(handle(), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(columnWidth(tester), DesktopSplitView.listWidth + 80);
      expect(c.read(desktopListWidthProvider), DesktopSplitView.listWidth + 80);
      expect(
        find.text('list ${(DesktopSplitView.listWidth + 80).round()} rail'),
        findsOneWidget,
        reason: 'the list lays itself out at the width it is given',
      );
      await tester.drag(handle(), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(columnWidth(tester), DesktopSplitView.listWidth - 40);
    });

    testWidgets('the chat keeps its room however far it is dragged',
        (tester) async {
      await pump(tester, width: 900);
      await tester.drag(handle(), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(
        900 - DesktopRail.width - 1 - columnWidth(tester),
        DesktopSplitView.detailMin,
      );
    });

    testWidgets('dragged narrow enough it folds to faces, and opens again',
        (tester) async {
      final c = await pump(tester, width: 1200);
      await tester.drag(handle(), const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(columnWidth(tester), DesktopSplitView.compactWidth);
      expect(c.read(desktopListCollapsedProvider), isTrue);
      await tester.drag(handle(), const Offset(250, 0));
      await tester.pumpAndSettle();
      expect(c.read(desktopListCollapsedProvider), isFalse);
      expect(columnWidth(tester), DesktopSplitView.compactWidth + 250);
    });

    testWidgets('a middling window\'s faces can be pulled open into the list',
        (tester) async {
      await pump(tester, width: 880);
      await tester.pumpAndSettle();
      expect(columnWidth(tester), DesktopSplitView.compactWidth);
      await tester.drag(handle(), const Offset(260, 0));
      await tester.pumpAndSettle();
      expect(columnWidth(tester), DesktopSplitView.compactWidth + 260);
      expect(find.text(t.desktopPickChat), findsOneWidget);
    });
  });

  testWidgets('middling on another section keeps its full column',
      (tester) async {
    await pump(tester, width: 760, branch: 1);
    expect(
      find.text('list ${DesktopSplitView.listWidth.round()} rail'),
      findsOneWidget,
    );
  });

  testWidgets('a chat tapped in the list opens in the pane, not over it',
      (tester) async {
    // Reported 2026-10-12 with a screenshot: a tap on a chat filled the
    // window. The list is handed a MediaQuery of its own 360 px, and
    // [desktopSplits] read that width as a phone's.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [
        platformCapabilitiesProvider
            .overrideWithValue(PlatformCapabilities.desktop),
        chatFoldersControllerProvider.overrideWith(_NoFolders.new),
        userChatFoldersControllerProvider.overrideWith(_NoUserFolders.new),
        visibleChatsProvider.overrideWithValue(const []),
        navBarControllerProvider.overrideWith(_Bar.new),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DesktopSplitView(
            list: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  onPressed: () => ref
                      .read(desktopOpenChatProvider.notifier)
                      .state = null,
                  child: Text(
                    desktopSplits(context, ref) ? 'splits' : 'pushes',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('splits'), findsOneWidget);
  });

  testWidgets('narrow: just the phone layout, at full width', (tester) async {
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

  testWidgets('narrowing to the phone layout and back keeps the chat open',
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
