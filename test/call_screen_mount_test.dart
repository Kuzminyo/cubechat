import 'dart:async';

import 'package:cubechat/core/transport/control_delivery.dart';
import 'package:cubechat/features/call/data/call_controller.dart';
import 'package:cubechat/features/call/data/call_media.dart';
import 'package:cubechat/features/call/data/turn_credentials_controller.dart';
import 'package:cubechat/features/call/presentation/call_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Media implements CallMedia {
  final _events = StreamController<CallMediaEvent>.broadcast(sync: true);
  @override
  Stream<CallMediaEvent> get events => _events.stream;
  @override
  Future<String> offer(Map<String, dynamic> configuration) async => 'offer';
  @override
  Future<String> answer(
          Map<String, dynamic> configuration, String remoteSdp) async =>
      'answer';
  @override
  Future<void> accept(String remoteSdp) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setSpeaker(bool speaker) async {}
  @override
  Future<void> close() => _events.close();
}

/// The call screen, mounted the way the app mounts it.
///
/// Tapping "Call" on a real phone turned the whole screen white and left it
/// there. `CallHost` lives in `MaterialApp.router`'s `builder`, which is
/// *above* the router — app.dart says so in a comment beside it — so nothing
/// the call screen draws has a Router, a Navigator or an Overlay above it. A
/// widget that looks one of those up throws while building, and a release
/// build paints a thrown build as an empty rectangle, which here was the size
/// of the screen. No test mounted the screen at all, which is how 1581 green
/// tests shipped it.
void main() {
  late StreamController<ReceivedCallSignal> signals;
  late CallController call;
  late GoRouter router;

  setUp(() {
    signals = StreamController<ReceivedCallSignal>(sync: true);
    call = CallController(
      signals: signals.stream,
      send: (peer, signal) async => const ControlDelivery(
        links: 1,
        certainty: DeliveryCertainty.confirmed,
      ),
      obtainTurn: () async => TurnAccess(
        urls: const ['turn:test'],
        username: 'u',
        password: 'p',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      ),
      microphone: () async => true,
      createMedia: _Media.new,
      record: (peer, outcome) {},
      peerName: (peer) => 'Alice',
      allowed: (_) => true,
      allowDirect: () => false,
      prepareAudio: () async {},
    );
    router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: Text('underneath')),
      ),
    ]);
  });

  tearDown(() async {
    // Not disposed here: the ProviderScope owns the controller once it is the
    // override, and unmounting the tree at the end of the test disposes it.
    await signals.close();
  });

  Widget app() => ProviderScope(
        overrides: [callControllerProvider.overrideWith((ref) => call)],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          // Exactly where app.dart puts it: around the router's output, in
          // the builder, with no route of its own.
          builder: (context, child) => CallHost(
            backButtonDispatcher: router.backButtonDispatcher,
            child: child!,
          ),
        ),
      );

  testWidgets('dialling puts a working call screen on top, not a blank one',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    unawaited(call.dial('peer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull,
        reason: 'a thrown build is the white screen');
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byIcon(Icons.call_end_rounded), findsOneWidget,
        reason: 'the one control a person needs is there to press');

    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('back while a call is showing does not pop the page beneath it',
      (tester) async {
    router = GoRouter(initialLocation: '/second', routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: Text('underneath')),
        routes: [
          GoRoute(
            path: 'second',
            builder: (_, __) => const Scaffold(body: Text('second page')),
          ),
        ],
      ),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);

    unawaited(call.dial('peer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The same path the Android back key takes into the app. Settled, and
    // asked of the router rather than of the widget tree: a page being popped
    // is still in the tree for the length of its exit animation, which made
    // the first version of this test pass with the fix switched off.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/second',
        reason: 'the call owns back while it is on screen');

    // And gives it back once the call is gone.
    call.hangUp();
    await tester.pump();
    call.dismiss();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/',
        reason: 'with no call on screen, back is the router\'s again');
  });

  testWidgets('a call folds into an island and the app underneath is usable '
      'again', (tester) async {
    var tapped = 0;
    router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: SafeArea(
            child: TextButton(
              onPressed: () => tapped++,
              child: const Text('underneath'),
            ),
          ),
        ),
      ),
    ]);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    unawaited(call.dial('peer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final before = tester.getTopLeft(find.text('underneath'));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CallIsland), findsOneWidget);
    expect(find.byType(CallScreen), findsNothing);

    await tester.tap(find.text('underneath'));
    expect(tapped, 1, reason: 'the chats are usable while the call is away');
    expect(
      tester.getTopLeft(find.text('underneath')).dy,
      greaterThanOrEqualTo(before.dy + CallIsland.height),
      reason: 'headers step down under the island instead of hiding behind it',
    );

    await tester.tap(find.byType(CallIsland));
    await tester.pump();
    expect(find.byType(CallScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a call that ends while folded away does not unfold', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    unawaited(call.dial('peer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();

    call.hangUp();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CallScreen), findsNothing);
    expect(find.byType(CallIsland), findsNothing);
    expect(call.peerId, isNull, reason: 'dismissed, not left behind');
  });
}
