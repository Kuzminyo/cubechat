import 'package:cubechat/core/widgets/freeze_when_offstage.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hidden tab must not pay for changes made by the tab in front of it. A
/// Galaxy S24+ log (2026-10-15) had the hidden Contacts tab rebuilt whole in
/// every frame of a chat open — 17-39 ms of build against 8.3.
final _counter = StateProvider<int>((ref) => 0);
var _builds = 0;

class _Tab extends ConsumerStatefulWidget {
  const _Tab();

  @override
  ConsumerState<_Tab> createState() => _TabState();
}

class _TabState extends ConsumerState<_Tab> with FreezeWhenOffstage {
  @override
  Widget build(BuildContext context) => buildUnlessOffstage(() {
        _builds++;
        return Text(
          '${ref.watch(_counter)}',
          textDirection: TextDirection.ltr,
        );
      });
}

Widget _host(bool onScreen) => UncontrolledProviderScope(
      container: _container,
      child: TickerMode(enabled: onScreen, child: const _Tab()),
    );

late ProviderContainer _container;

void main() {
  setUp(() {
    _container = ProviderContainer();
    _builds = 0;
  });
  tearDown(() => _container.dispose());

  testWidgets('a hidden tab neither rebuilds nor keeps watching', (t) async {
    await t.pumpWidget(_host(true));
    expect(find.text('0'), findsOneWidget);

    await t.pumpWidget(_host(false));
    final hidden = _builds;
    for (var i = 1; i <= 5; i++) {
      _container.read(_counter.notifier).state = i;
      await t.pump();
    }
    expect(_builds, hidden, reason: 'five changes, no rebuilds while hidden');
    expect(find.text('0'), findsOneWidget, reason: 'it shows what it had');
  });

  testWidgets('shown again, it rebuilds once with what changed', (t) async {
    await t.pumpWidget(_host(true));
    await t.pumpWidget(_host(false));
    _container.read(_counter.notifier).state = 7;
    await t.pump();

    await t.pumpWidget(_host(true));
    expect(find.text('7'), findsOneWidget);

    final shown = _builds;
    _container.read(_counter.notifier).state = 8;
    await t.pump();
    expect(_builds, shown + 1, reason: 'watching again once on screen');
    expect(find.text('8'), findsOneWidget);
  });
}
