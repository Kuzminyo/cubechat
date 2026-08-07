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

class _CaptureKnownPeersController extends KnownPeersController {
  @override
  Map<String, KnownPeer> build() => {
        _pubkey: KnownPeer(
          pubkeyHex: _pubkey,
          displayName: 'Alice',
          lastSeen: DateTime(2026),
        ),
      };
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String filename,
) async {
  await expectLater(
    find.byKey(boundaryKey),
    matchesGoldenFile('../.codex/design-qa/$filename'),
  );
}

void main() {
  testWidgets('capture contact profile states', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knownPeersControllerProvider.overrideWith(
            _CaptureKnownPeersController.new,
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
          // A static stand-in for AuroraBackground: the real one drifts off a
          // wall-clock Stopwatch, so its blobs land at a different phase on
          // every run and the capture never matches itself.
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
              child: ContactProfileScreen(
                peerPubkeyHex: _pubkey,
                peerLabel: 'Alice',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 350));
    await _capture(tester, boundaryKey, 'implementation-actions-new-360x800.png');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -480),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await _capture(tester, boundaryKey, 'implementation-sections-360x800.png');
  });
}
