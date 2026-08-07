@Tags(['golden'])
// Golden comparisons, so they are pinned to the machine that recorded them.
// Font rasterisation differs between platforms — these goldens were captured on
// Windows and a Linux runner reproduces them within about 3% of pixels, which
// is a real difference and not a real regression. Re-recording on CI would only
// move the failure to the developer's machine.
//
// Excluded from CI with `--exclude-tags golden`; run them locally, where the
// comparison means something, with `flutter test --tags golden`.
library;

import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/data/recent_searches_controller.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chat_search_screen.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Design-QA capture of the search screen's resting state.
///
/// Static gradient rather than AuroraBackground: that one drifts off a
/// wall-clock Stopwatch, so its blobs land at a different phase every run and
/// the capture never matches itself.
class _FakeMessages extends MessagesController {
  @override
  Map<String, List<Message>> build() => {
        for (final e in {'alice': 40, 'bohdan': 12, 'chris': 5, 'dana': 2}
            .entries)
          e.key: List.generate(
            e.value,
            (i) => Message(
              id: 'm$i',
              chatId: e.key,
              text: 'hi',
              sentAt: DateTime(2026),
              isMine: false,
            ),
          ),
      };
}

class _FakeRecents extends RecentSearchesController {
  @override
  List<String> build() => ['chris', 'dana'];
}

Chat _chat(String id, String name, {bool favorite = false}) => Chat(
      id: id,
      peerId: id,
      peerName: name,
      lastMessage: 'Secured · Noise XX',
      lastTime: DateTime(2026, 8, 3, 11, 4),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
      isFavorite: favorite,
    );

void main() {
  testWidgets('capture chat search resting state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider.overrideWithValue([
            _chat('alice', 'Alice'),
            _chat('bohdan', 'Bohdan'),
            _chat('chris', 'Chris', favorite: true),
            _chat('dana', 'Dana'),
          ]),
          messagesControllerProvider.overrideWith(_FakeMessages.new),
          recentSearchesControllerProvider.overrideWith(_FakeRecents.new),
        ],
        child: MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: RepaintBoundary(
            key: boundaryKey,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.bgTop, AppColors.bgBottom],
                ),
              ),
              child: ChatSearchScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile('../.codex/design-qa/chat-search-360x800.png'),
    );
  });
}
