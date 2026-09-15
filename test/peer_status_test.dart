import 'package:cubechat/features/peers/data/peer_activity.dart';
import 'package:cubechat/features/peers/presentation/peer_status.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The line under a person's name, shared by the chat header and the peek.
/// Each step outranks the ones after it — see [peerStatusLine].
void main() {
  late BuildContext context;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  String line({
    bool blocked = false,
    String? session,
    PeerActivity? activity,
    bool online = false,
    bool hideTimes = false,
    DateTime? lastPresent,
  }) =>
      peerStatusLine(
        context,
        blocked: blocked,
        sessionNote: session,
        activity: activity,
        online: online,
        hideTimes: hideTimes,
        lastPresent: lastPresent,
      );

  testWidgets('each fact outranks the ones below it', (tester) async {
    await pump(tester);
    final minutesAgo = DateTime.now().subtract(const Duration(minutes: 12));

    expect(
      line(
        blocked: true,
        session: 'connecting',
        activity: PeerActivity.typing,
        online: true,
      ),
      'blocked',
      reason: 'nothing a blocked phone says is repeated',
    );
    expect(
      line(session: 'connecting', activity: PeerActivity.typing, online: true),
      'connecting',
    );
    expect(
      line(activity: PeerActivity.sendingVideo, online: true),
      'sending a video…',
      reason: 'doing something is more than being online',
    );
    expect(line(online: true, hideTimes: true), 'online',
        reason: 'hidden times hide history, not now');
    expect(line(hideTimes: true, lastPresent: minutesAgo), 'last seen recently');
    expect(line(), 'offline');
    expect(line(lastPresent: minutesAgo), isNot('offline'));
  });

  testWidgets('every activity has words and a mark', (tester) async {
    await pump(tester);
    final t = AppLocalizations.of(context);
    final labels = {
      for (final a in PeerActivity.values) peerActivityLabel(t, a),
    };
    final icons = {for (final a in PeerActivity.values) peerActivityIcon(a)};
    expect(labels, hasLength(PeerActivity.values.length));
    expect(icons, hasLength(PeerActivity.values.length));
  });
}
