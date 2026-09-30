import 'package:cubechat/features/chat/domain/message_route_badge.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which way a message travelled, as the small mark beside its time. The data
/// was on every message already; what is pinned here is when the mark shows
/// and when it must not claim anything.
void main() {
  Message msg({
    required bool mine,
    MessageRoute? route,
    int? hops,
    MessageStatus status = MessageStatus.delivered,
  }) =>
      Message(
        id: 'm',
        chatId: 'c',
        text: 'hi',
        sentAt: DateTime(2026, 9, 30),
        isMine: mine,
        status: status,
        route: route,
        routeHops: hops,
      );

  test('each road has its own mark, mine and theirs alike', () {
    for (final mine in [true, false]) {
      expect(
        routeBadgeFor(msg(mine: mine, route: MessageRoute.bluetooth))?.kind,
        RouteBadgeKind.bluetooth,
      );
      expect(
        routeBadgeFor(msg(mine: mine, route: MessageRoute.internet))?.kind,
        RouteBadgeKind.internet,
      );
      final mesh = routeBadgeFor(
        msg(mine: mine, route: MessageRoute.mesh, hops: 3),
      );
      expect(mesh?.kind, RouteBadgeKind.mesh);
      expect(mesh?.hops, 3);
    }
  });

  test('no road recorded, or not there yet: no mark', () {
    // Old messages carry no route; a queued one already shows the cloud.
    expect(routeBadgeFor(msg(mine: false)), isNull);
    expect(routeBadgeFor(msg(mine: true, route: MessageRoute.queued)), isNull);
    // Ours and still on its way — the road it will take is not a fact yet.
    for (final status in [MessageStatus.sending, MessageStatus.failed]) {
      expect(
        routeBadgeFor(
          msg(mine: true, route: MessageRoute.mesh, status: status),
        ),
        isNull,
      );
    }
  });

  Future<void> pumpBubble(WidgetTester tester, Message m) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: MessageBubble(message: m, chatId: 'peer')),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the bubble carries the mark beside its time', (tester) async {
    // findsWidgets, not one: the bubble holds an invisible copy of its footer
    // to size itself (see _FooterAtEnd), so the time row is built twice.
    await pumpBubble(tester, msg(mine: false, route: MessageRoute.bluetooth));
    expect(find.byIcon(Icons.bluetooth_rounded), findsWidgets);

    await pumpBubble(tester, msg(mine: true, route: MessageRoute.internet));
    expect(find.byIcon(Icons.public_rounded), findsWidgets);

    await pumpBubble(
      tester,
      msg(mine: false, route: MessageRoute.mesh, hops: 3),
    );
    expect(find.byIcon(Icons.hub_rounded), findsWidgets);
    expect(find.text('3'), findsWidgets);

    await pumpBubble(tester, msg(mine: false));
    expect(find.byIcon(Icons.bluetooth_rounded), findsNothing);
    expect(find.byIcon(Icons.public_rounded), findsNothing);
    expect(find.byIcon(Icons.hub_rounded), findsNothing);
  });

  test('a mesh hop count below two says nothing worth a number', () {
    expect(
      routeBadgeFor(msg(mine: false, route: MessageRoute.mesh, hops: 1))?.hops,
      isNull,
    );
    expect(
      routeBadgeFor(msg(mine: false, route: MessageRoute.mesh))?.hops,
      isNull,
    );
  });
}
