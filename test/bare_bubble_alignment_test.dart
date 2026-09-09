import 'dart:io';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/features/chat/presentation/widgets/video_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// A message with no bubble still belongs against the edge.
///
/// Reported from a screenshot: a lone emoji sent as a reply sat in the middle
/// of its row with the clock and tick beside it, while every ordinary outgoing
/// bubble above it hugged the right. The row and the outer column were already
/// right-aligning; what was not was the column *inside* the bubble, which is
/// hard-coded to `start` because inside a box that is the only sensible
/// answer.
///
/// A bare message has no box. Its column is as wide as its widest row — here
/// the reply quote — so the picture and the clock were left-aligned inside a
/// quote-wide column, which is exactly as far from the edge as the quote is
/// long.
///
/// Measured rather than captured: a golden would answer "these pixels moved",
/// and the question is "is the right edge of the emoji the right edge of the
/// column".
Message _replyEmoji({required bool mine}) => Message(
      id: 'm1',
      chatId: 'peer',
      text: '🙂',
      sentAt: DateTime(2026, 9, 8, 10, 11),
      isMine: mine,
      replyToWireId: 'm0',
      replyPreview: 'a quote long enough to be the widest thing in the column',
    );

Future<Rect> _pump(WidgetTester tester, Message m) async {
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
        home: Scaffold(
          body: MessageBubble(message: m, chatId: 'peer'),
        ),
      ),
    ),
  );
  await tester.pump();
  // The clock, not the picture: a single emoji with a drawing in the pack is
  // rendered as that drawing rather than as text, and the clock is half of
  // what was reported adrift anyway.
  return tester.getRect(find.text('10:11'));
}

void main() {
  testWidgets('ours ends where the quote above it ends', (tester) async {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final clock = await _pump(tester, _replyEmoji(mine: true));
    final quote = tester.getRect(find.textContaining('a quote long enough'));

    expect(
      clock.right,
      closeTo(quote.right, 24),
      reason: 'left-aligned in a quote-wide column, the clock lands a whole '
          'quote away from the edge — which is the reported bug',
    );
    expect(
      clock.left - quote.left,
      greaterThan(24),
      reason: 'and it must not simply be the full width of the quote',
    );
  });

  testWidgets('theirs still starts at the left', (tester) async {
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final clock = await _pump(tester, _replyEmoji(mine: false));
    final quote = tester.getRect(find.textContaining('a quote long enough'));

    expect(
      clock.left,
      closeTo(quote.left, 24),
      reason: 'an incoming bare message is against the left edge already, and '
          'flipping it would push it away from that one instead',
    );
  });
  testWidgets('a circular video has no message fill, border or inset',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('cubechat_circle_bare_');
    final clip = File('${dir.path}/circle.mp4')..writeAsBytesSync([0, 1, 2, 3]);
    addTearDown(() => dir.deleteSync(recursive: true));
    final message = Message(
      id: 'circle',
      chatId: 'peer',
      text: 'video/mp4',
      sentAt: DateTime(2026, 9, 9),
      isMine: true,
      kind: MessageKind.file,
      fileName: VideoBubble.circleFileName,
      filePath: clip.path,
    );
    // Offstage keeps the video decoder out of this decoration-only check.
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Offstage(
              child: MessageBubble(message: message, chatId: 'peer'),
            ),
          ),
        ),
      ),
    );
    final video = find.byType(VideoBubble, skipOffstage: false);
    expect(video, findsOneWidget);
    final parents = tester.widgetList<Container>(
      find.ancestor(
        of: video,
        matching: find.byType(Container, skipOffstage: false),
      ),
    );
    final surface =
        parents.firstWhere((box) => box.decoration is BoxDecoration);
    final decoration = surface.decoration! as BoxDecoration;
    expect(decoration.color, isNull);
    expect(decoration.gradient, isNull);
    expect(decoration.border, isNull);
    expect(surface.padding, EdgeInsets.zero);
    await tester.pumpWidget(const SizedBox());
  });
}
