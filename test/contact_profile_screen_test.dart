import 'package:cubechat/core/widgets/aurora_background.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/features/peers/presentation/contact_profile_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _pubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _TestKnownPeersController extends KnownPeersController {
  @override
  Map<String, KnownPeer> build() => {
        _pubkey: KnownPeer(
          pubkeyHex: _pubkey,
          displayName: 'Alice',
          lastSeen: DateTime(2026),
        ),
      };
}

void main() {
  testWidgets('contact profile fits a narrow phone and exposes real actions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knownPeersControllerProvider.overrideWith(
            _TestKnownPeersController.new,
          ),
          chatsProvider.overrideWithValue([
            Chat(
              id: _pubkey,
              peerId: _pubkey,
              peerName: 'Alice',
              lastMessage: 'Hello',
              lastTime: DateTime(2026),
              unreadCount: 0,
              isMesh: true,
              isOnline: true,
            ),
          ]),
        ],
        child: MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: const AuroraBackground(
            child: ContactProfileScreen(
              peerPubkeyHex: _pubkey,
              peerLabel: 'Alice',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('\u0427\u0430\u0442'), findsOneWidget);
    expect(
      find.text('\u0411\u0435\u0437 \u0437\u0432\u0443\u043a\u0443'),
      findsOneWidget,
    );
    expect(
      find.text(
        '\u041f\u0456\u0434\u0442\u0432\u0435\u0440\u0434\u0438\u0442\u0438',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '\u0417\u0430\u0431\u043b\u043e\u043a\u0443\u0432\u0430\u0442\u0438',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text(
        '\u0414\u0456\u0457 \u043a\u043e\u043d\u0442\u0430\u043a\u0442\u0443',
      ),
      findsOneWidget,
    );
    /*
    expect(
      find.text(
        '\u041a\u043e\u043f\u0456\u044e\u0432\u0430\u0442\u0438 ID \u043a\u043e\u043d\u0442\u0430\u043a\u0442\u0443',
      ),
      findsOneWidget,
    );
    */
    expect(
      find.text(
        '\u0410\u0432\u0442\u043e\u043e\u0447\u0438\u0449\u0435\u043d\u043d\u044f \u0447\u0430\u0442\u0443',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '\u041f\u043e\u0434\u0456\u043b\u0438\u0442\u0438\u0441\u044f \u043a\u043e\u043d\u0442\u0430\u043a\u0442\u043e\u043c',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '\u0417\u0430\u0431\u043e\u0440\u043e\u043d\u0438\u0442\u0438 \u043a\u043e\u043f\u0456\u044e\u0432\u0430\u043d\u043d\u044f',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '\u0412\u0438\u0434\u0430\u043b\u0438\u0442\u0438 \u0437 \u043a\u043e\u043d\u0442\u0430\u043a\u0442\u0456\u0432',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '\u041a\u043e\u043f\u0456\u044e\u0432\u0430\u0442\u0438 ID \u043a\u043e\u043d\u0442\u0430\u043a\u0442\u0443',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.text(
        '\u0417\u0430\u0431\u043b\u043e\u043a\u0443\u0432\u0430\u0442\u0438',
      ),
    );
    await tester.pump();

    expect(
      find.text(
        '\u0420\u043e\u0437\u0431\u043b\u043e\u043a\u0443\u0432\u0430\u0442\u0438',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
