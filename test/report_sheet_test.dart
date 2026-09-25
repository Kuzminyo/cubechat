import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/moderation/data/hidden_authors.dart';
import 'package:cubechat/features/moderation/data/report_client.dart';
import 'package:cubechat/features/moderation/domain/report.dart';
import 'package:cubechat/features/moderation/presentation/report_sheet.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A3: one tap on "Send" reports, blocks (or hides the channel author) and
/// takes the message off the screen — and the two local steps happen even
/// when the server refuses, since the person asked for them.

final _peer = 'a' * 64;
final _sentAt = DateTime.utc(2026, 9, 25, 12);

class _Client extends ReportClient {
  _Client(Ref ref, this.outcome) : super(ref: ref);

  /// true / false as `send` returns them; null throws the permanent refusal.
  final bool? outcome;
  final sent = <ModerationReport>[];

  @override
  Future<bool> send(ModerationReport report) async {
    sent.add(report);
    if (outcome == null) throw const ReportRejectedException();
    return outcome!;
  }
}

class _Peers extends KnownPeersController {
  final blocked = <String>[];

  @override
  Map<String, KnownPeer> build() => {
        _peer: KnownPeer(
          pubkeyHex: _peer,
          displayName: 'them',
          lastSeen: DateTime(2026),
        ),
      };

  @override
  Future<void> setBlocked(String pubkeyHex, bool blocked) async {
    if (blocked) this.blocked.add(pubkeyHex);
  }
}

class _Messages extends MessagesController {
  final deleted = <String>[];

  @override
  Map<String, List<Message>> build() => const {};

  @override
  void deleteLocal(String peerId, String messageId) =>
      deleted.add('$peerId/$messageId');
}

class _Hidden extends HiddenAuthors {
  @override
  Set<String> build() => <String>{};

  @override
  Future<void> hide(String fingerprint) async {
    state = {...state, fingerprint};
  }
}

void main() {
  late _Client client;
  late _Peers peers;
  late _Messages messages;
  late ProviderContainer container;

  Future<void> open(
    WidgetTester tester, {
    required bool? outcome,
    required ReportContext reportContext,
    String? targetHex,
    Message? message,
    String? chatId,
  }) async {
    peers = _Peers();
    messages = _Messages();
    container = ProviderContainer(
      overrides: [
        reportClientProvider.overrideWith((ref) => client = _Client(ref, outcome)),
        knownPeersControllerProvider.overrideWith(() => peers),
        messagesControllerProvider.overrideWith(() => messages),
        hiddenAuthorsProvider.overrideWith(_Hidden.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showReportSheet(
                  context,
                  reportContext: reportContext,
                  targetHex: targetHex,
                  message: message,
                  chatId: chatId,
                  channelId: reportContext == ReportContext.channel
                      ? '#room'
                      : null,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.text('Send report'));
    await tester.pump();
    await tester.pump();
    // Past the toast's own dismiss timer, so no timer outlives the test.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  Message incoming({String? authorId, String text = 'go away'}) => Message(
        id: 'm1',
        chatId: authorId == null ? _peer : '#room',
        text: text,
        sentAt: _sentAt,
        isMine: false,
        authorId: authorId,
      );

  testWidgets('a direct report sends the payload, blocks and removes',
      (tester) async {
    await open(
      tester,
      outcome: true,
      reportContext: ReportContext.direct,
      targetHex: _peer,
      message: incoming(),
      chatId: _peer,
    );
    await send(tester);

    final json = client.sent.single.toJson();
    expect(json['context'], 'direct');
    expect(json['target'], _peer);
    expect(json['message'], {
      'text': 'go away',
      'kind': 'text',
      'sentAt': _sentAt.millisecondsSinceEpoch,
    });
    expect(peers.blocked, [_peer]);
    expect(messages.deleted, ['$_peer/m1']);
  });

  testWidgets('a channel message report hides its author, blocks nobody',
      (tester) async {
    const author = '0123456789abcdef';
    await open(
      tester,
      outcome: true,
      reportContext: ReportContext.channel,
      targetHex: author,
      message: incoming(authorId: author),
      chatId: '#room',
    );
    await send(tester);

    expect(client.sent.single.toJson()['target'], author);
    expect(container.read(hiddenAuthorsProvider), {author});
    expect(peers.blocked, isEmpty);
    expect(messages.deleted, ['#room/m1']);
  });

  testWidgets('a refused report still blocks and removes', (tester) async {
    await open(
      tester,
      outcome: null,
      reportContext: ReportContext.direct,
      targetHex: _peer,
      message: incoming(),
      chatId: _peer,
    );
    await send(tester);

    expect(client.sent, hasLength(1));
    expect(peers.blocked, [_peer]);
    expect(messages.deleted, ['$_peer/m1']);
  });

  testWidgets('a note typed under Other is dropped when another reason is sent',
      (tester) async {
    await open(
      tester,
      outcome: true,
      reportContext: ReportContext.general,
    );
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'context for you');
    await tester.tap(find.text('Spam'));
    await tester.pumpAndSettle();
    await send(tester);

    final json = client.sent.single.toJson();
    expect(json['reason'], 'spam');
    expect(json.containsKey('note'), isFalse);
  });

  testWidgets('a shared location is reported as its preview, not coordinates',
      (tester) async {
    await open(
      tester,
      outcome: false,
      reportContext: ReportContext.direct,
      targetHex: _peer,
      message: incoming(text: 'cubechat:loc:v1:NTAuNDUsMzAuNTI'),
      chatId: _peer,
    );
    await send(tester);

    final text = (client.sent.single.toJson()['message']!
        as Map<String, Object?>)['text']! as String;
    expect(text, isNot(contains('cubechat:')));
  });
}
