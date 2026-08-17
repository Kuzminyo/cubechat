import 'dart:ui' as ui;

import 'package:cubechat/features/chat/presentation/widgets/message_spotlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holding a message blurs everything else.
///
/// The blur is the whole point of the screen and it is also the part that
/// silently does nothing when it is built wrong, so both halves of "built
/// right" are pinned here.
void main() {
  Future<void> open(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) {
          ctx = context;
          return const Scaffold(body: Center(child: Text('conversation')));
        },
      ),
    ));

    unawaited_showSpotlight(ctx);
    await tester.pumpAndSettle();
  }

  testWidgets('the backdrop filter is clipped', (tester) async {
    await open(tester);

    // A BackdropFilter with no clip around it has unbounded effect bounds, and
    // several backends answer that by rendering nothing whatsoever — which is
    // what "there is no blur" was. Every other blurred surface in this app sits
    // inside a clip; this one covers the whole screen and looked like it needed
    // no shape. It needs the shape to be *drawn*, not to be rounded.
    final blur = find.byType(BackdropFilter).first;
    expect(
      find.ancestor(of: blur, matching: find.byType(ClipRect)),
      findsWidgets,
      reason: 'an unclipped full-screen BackdropFilter draws nothing',
    );
  });

  testWidgets('the blur has a real radius once it has settled', (tester) async {
    await open(tester);

    final widget = tester.widget<BackdropFilter>(
      find.byType(BackdropFilter).first,
    );
    // ImageFilter has no public sigma, so the description is what there is to
    // check. Zero would mean the animation never ran, or ran and was optimised
    // away.
    expect(widget.filter, isA<ui.ImageFilter>());
    expect(widget.filter.toString(), isNot(contains('sigmaX: 0.0,')));
  });

  testWidgets('the message is drawn again on top, and it is inert',
      (tester) async {
    await open(tester);

    // The lit message is a second copy of the bubble rather than a hole punched
    // in the blur — you cannot punch a hole in a backdrop filter — so it has to
    // be present and it has to absorb taps rather than letting them reach the
    // real one underneath.
    expect(find.text('the message'), findsOneWidget);
    expect(find.byType(AbsorbPointer), findsWidgets);
  });

  testWidgets('the reactions and the actions are both offered',
      (tester) async {
    await open(tester);

    expect(find.text('❤️'), findsOneWidget);
    expect(find.text('👍'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
  });

  testWidgets('every label has a Material to be styled by', (tester) async {
    await open(tester);

    // Text with no Material ancestor gets Flutter's fallback style: black with
    // a yellow double underline. That is the framework saying "nothing told me
    // how to draw this", and it is what the route looked like — a bare Stack
    // pushed on the navigator, with the message copy and every action label
    // underlined in yellow.
    for (final label in ['the message', 'Reply', '❤️']) {
      expect(
        find.ancestor(of: find.text(label), matching: find.byType(Material)),
        findsWidgets,
        reason: '"$label" would be drawn with the yellow debug underline',
      );
    }
  });
}

/// Opens the spotlight without awaiting it — the route stays up for the test to
/// look at.
void unawaited_showSpotlight(BuildContext context) {
  showMessageSpotlight(
    context: context,
    anchor: const Rect.fromLTWH(20, 200, 300, 60),
    bubble: const Material(child: Text('the message')),
    reactions: const ['❤️', '👍'],
    actions: const [
      SpotlightAction(
        id: 'reply',
        icon: Icons.reply_rounded,
        label: 'Reply',
      ),
    ],
  );
}
