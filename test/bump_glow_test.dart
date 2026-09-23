import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:cubechat/features/airdrop/data/bump_controller.dart';
import 'package:cubechat/features/airdrop/presentation/airdrop_navigation.dart';
import 'package:cubechat/features/airdrop/presentation/bump_glow.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _bob = 'b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0';

/// The controller without its radio: the tests set its state by hand and
/// record what the card asks of it.
class _FakeBump extends BumpController {
  _FakeBump([this.initial = const BumpState()]);

  final BumpState initial;
  var adds = 0;
  var dismisses = 0;

  @override
  BumpState build() => initial;

  void emit(BumpState next) => state = next;

  @override
  void dismiss() {
    dismisses++;
    if (state.event != null) state = BumpState(warmth: state.warmth);
  }

  @override
  Future<String?> addContact() async {
    adds++;
    dismiss();
    return _bob;
  }
}

/// A signed card with [name] in it — the same bytes a bump carries.
Future<Uint8List> _card(String name) async {
  final ed = Ed25519();
  final keys = await (await ed.newKeyPair()).extract();
  return PeerAnnouncement(
    pubkey: Uint8List.fromList(List.filled(32, 0xb0)),
    signPubkey: Uint8List.fromList(keys.publicKey.bytes),
    signedPrekeyPub: Uint8List(32),
    nostrPubkey: Uint8List(32),
    nickname: name,
  ).sign(keys);
}

/// Every layer in the tree by type, so "adds nothing" means nothing at all,
/// not only nothing offscreen.
Map<String, int> _census(Layer? layer, [Map<String, int>? into]) {
  final counts = into ?? <String, int>{};
  for (var node = layer; node != null; node = node.nextSibling) {
    final name = node.runtimeType.toString();
    counts[name] = (counts[name] ?? 0) + 1;
    if (node is ContainerLayer) _census(node.firstChild, counts);
  }
  return counts;
}

Widget _app(
  _FakeBump bump, {
  Widget glow = const BumpGlow(),
  bool reduced = false,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: Stack(children: [Positioned.fill(child: glow)]),
        ),
      ),
      GoRoute(
        path: '/chat/:peerId',
        builder: (_, state) => Scaffold(
          body: Text(
            'chat ${state.pathParameters['peerId']} '
            '${state.uri.queryParameters['name']}',
          ),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [bumpControllerProvider.overrideWith(() => bump)],
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('uk'),
      builder: (context, child) => reduced
          ? MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : child!,
    ),
  );
}

void main() {
  late List<Object?> haptics;

  setUp(() {
    haptics = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(BumpGlow)));

  testWidgets('at rest it paints nothing, ticks nothing and adds no layer',
      (tester) async {
    await tester.pumpWidget(_app(_FakeBump(), glow: const SizedBox.expand()));
    await tester.pump();
    final bare = _census(tester.binding.renderViews.first.debugLayer);

    await tester.pumpWidget(_app(_FakeBump()));
    await tester.pump();

    expect(find.byKey(const Key('bump-glow')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(BumpGlow),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
    expect(tester.binding.transientCallbackCount, 0);
    final idle = _census(tester.binding.renderViews.first.debugLayer);
    // Every layer, offscreen passes (test/layer_budget_test.dart's concern)
    // included: the router's own scaffolding brings an OpacityLayer, and
    // the glow must bring nothing on top of it.
    expect(idle, bare, reason: 'an idle glow must cost the page nothing');
  });

  testWidgets('warmth lights the glow, and it goes out when warmth does',
      (tester) async {
    final bump = _FakeBump(const BumpState(warmth: 0.6));
    await tester.pumpWidget(_app(bump));
    await tester.pump();
    expect(find.byKey(const Key('bump-glow')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bump-glow')), findsOneWidget);

    bump.emit(const BumpState());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bump-glow')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(haptics, isEmpty, reason: 'warmth alone is not an event');
  });

  testWidgets(
      'a stranger\'s card shows the name from the card and "Додати" adds them',
      (tester) async {
    final card = (await tester.runAsync(() => _card('Боб')))!;
    final bump = _FakeBump();
    await tester.pumpWidget(_app(bump));
    await tester.pump();

    final event = BumpContact(
      _bob,
      'CubeChat',
      DateTime(2026, 9, 23),
      card: card,
      alreadyContact: false,
    );
    bump.emit(BumpState(warmth: 1, event: event));
    await tester.pump();
    // The card is verified off the frame; let it finish.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('Боб'), findsOneWidget);
    expect(find.text('Додати'), findsOneWidget);
    expect(haptics, ['HapticFeedbackType.heavyImpact']);

    // Warmth moving under the same event is not a second event.
    bump.emit(BumpState(warmth: 0.7, event: event));
    await tester.pumpAndSettle();
    expect(haptics, hasLength(1));

    await tester.tap(find.text('Додати'));
    await tester.pumpAndSettle();
    expect(bump.adds, 1);
    expect(find.text('Додано Боб'), findsOneWidget);
    expect(find.text('Додати'), findsNothing);

    // Let the toast's own timer run out.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('a contact already known offers to write, and it opens the chat',
      (tester) async {
    final bump = _FakeBump();
    await tester.pumpWidget(_app(bump));
    await tester.pump();

    bump.emit(
      BumpState(
        event: BumpContact(
          _bob,
          'Жека',
          DateTime(2026, 9, 23),
          card: Uint8List(8),
          alreadyContact: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // An unreadable card falls back to the name the controller gave.
    expect(find.text('Жека'), findsOneWidget);
    expect(find.text('Вже у контактах'), findsOneWidget);
    expect(find.text('Додати'), findsNothing);

    await tester.tap(find.text('Написати'));
    await tester.pumpAndSettle();
    expect(find.text('chat $_bob Жека'), findsOneWidget);
    expect(bump.dismisses, 1);
  });

  testWidgets('the close button dismisses the card', (tester) async {
    final bump = _FakeBump();
    await tester.pumpWidget(_app(bump));
    await tester.pump();

    bump.emit(
      BumpState(
        event: BumpContact(
          _bob,
          'Жека',
          DateTime(2026, 9, 23),
          card: Uint8List(8),
          alreadyContact: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(bump.dismisses, 1);
    expect(find.text('Жека'), findsNothing);
    expect(find.byKey(const Key('bump-glow')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion shows the card at once, with no wave',
      (tester) async {
    final bump = _FakeBump();
    await tester.pumpWidget(_app(bump, reduced: true));
    await tester.pump();

    bump.emit(
      BumpState(
        event: BumpContact(
          _bob,
          'Жека',
          DateTime(2026, 9, 23),
          card: Uint8List(8),
          alreadyContact: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Жека'), findsOneWidget);
    expect(find.text('Додати'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    expect(haptics, hasLength(1));
  });

  testWidgets('files going out say so, then leave it to the progress card',
      (tester) async {
    final bump = _FakeBump();
    await tester.pumpWidget(_app(bump));
    await tester.pump();

    bump.emit(
      BumpState(
        warmth: 1,
        event: BumpSentFiles(_bob, 'Оля', DateTime(2026, 9, 23), 2),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Надсилаю Оля'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(bump.dismisses, 1);
    bump.emit(const BumpState());
    await tester.pumpAndSettle();
    expect(find.text('Надсилаю Оля'), findsNothing);
    expect(find.byKey(const Key('bump-glow')), findsNothing);
  });

  testWidgets('files coming in say who is sending', (tester) async {
    final bump = _FakeBump();
    await tester.pumpWidget(_app(bump));
    await tester.pump();

    bump.emit(
      BumpState(
        event: BumpReceivingFiles(_bob, 'Оля', DateTime(2026, 9, 23)),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Оля надсилає вам файли'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Оля надсилає вам файли'), findsNothing);
  });

  testWidgets('leaving the page drops the card, so it is not there next visit',
      (tester) async {
    final bump = _FakeBump();
    await tester.pumpWidget(_app(bump));
    await tester.pump();
    final c = container(tester);
    c.read(airdropPageOnScreenProvider.notifier).state = true;
    await tester.pump();

    bump.emit(
      BumpState(
        warmth: 0.5,
        event: BumpContact(
          _bob,
          'Жека',
          DateTime(2026, 9, 23),
          card: Uint8List(8),
          alreadyContact: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    c.read(airdropPageOnScreenProvider.notifier).state = false;
    // The real controller zeroes warmth on the way out too.
    bump.emit(BumpState(event: c.read(bumpControllerProvider).event));
    await tester.pump();

    expect(bump.dismisses, 1);
    expect(c.read(bumpControllerProvider).event, isNull);
    expect(find.text('Жека'), findsNothing);
    expect(find.byKey(const Key('bump-glow')), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
