@Tags(['golden'])
library;

import 'dart:typed_data';

import 'package:cubechat/core/identity/avatar_controller.dart';
import 'package:cubechat/core/identity/nickname_controller.dart';
import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/core/util/location_service.dart';
import 'package:cubechat/features/map/data/shared_map_locations_provider.dart';
import 'package:cubechat/features/map/presentation/people_map_screen.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/data/peer_avatars_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _alice =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _bob = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _MapKnownPeers extends KnownPeersController {
  @override
  Map<String, KnownPeer> build() => {
        _alice: KnownPeer(
          pubkeyHex: _alice,
          displayName: 'Alice',
          lastSeen: DateTime(2026),
        ),
        _bob: KnownPeer(
          pubkeyHex: _bob,
          displayName: 'Bob',
          lastSeen: DateTime(2026),
        ),
      };
}

class _MapPeerAvatars extends PeerAvatarsController {
  @override
  Map<String, Uint8List> build() => const {};
}

class _MapAvatar extends AvatarController {
  @override
  Uint8List? build() => null;
}

class _MapNickname extends NicknameController {
  @override
  String build() => 'You';
}

class _MapPrivacy extends PrivacySettingsController {
  @override
  PrivacySettings build() => const PrivacySettings(
        shareLastSeen: true,
        shareReadReceipts: true,
        shareMapLocation: true,
      );
}

void main() {
  testWidgets('capture the people map at a phone viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();
    final sentAt = DateTime.now();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knownPeersControllerProvider.overrideWith(_MapKnownPeers.new),
          peerAvatarsControllerProvider.overrideWith(_MapPeerAvatars.new),
          avatarProvider.overrideWith(_MapAvatar.new),
          nicknameControllerProvider.overrideWith(_MapNickname.new),
          sharedMapLocationsProvider.overrideWithValue({
            _alice: SharedMapLocation(
              chatId: _alice,
              location: const SharedLocation(
                latitude: 50.4501,
                longitude: 30.5234,
              ),
              sentAt: sentAt,
            ),
            _bob: SharedMapLocation(
              chatId: _bob,
              location: const SharedLocation(
                latitude: 50.455,
                longitude: 30.535,
              ),
              sentAt: sentAt,
            ),
          }),
        ],
        child: MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            fontFamily: 'MapGolden',
          ),
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
              child: TickerMode(
                enabled: false,
                child: PeopleMapScreen(
                  tileProvider: NetworkTileProvider(
                    cachingProvider: const DisabledMapCachingProvider(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.text('\u041a\u0430\u0440\u0442\u0430'),
      findsOneWidget,
    );
    expect(
      find.text(
          '\u0413\u0435\u043e\u043b\u043e\u043a\u0430\u0446\u0456\u044e \u043f\u0440\u0438\u0445\u043e\u0432\u0430\u043d\u043e'),
      findsNothing,
    );

    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile('../.codex/design-qa/people-map-360x800.png'),
    );
  });

  testWidgets('tapping the own marker opens the mini profile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knownPeersControllerProvider.overrideWith(_MapKnownPeers.new),
          peerAvatarsControllerProvider.overrideWith(_MapPeerAvatars.new),
          avatarProvider.overrideWith(_MapAvatar.new),
          nicknameControllerProvider.overrideWith(_MapNickname.new),
          privacySettingsProvider.overrideWith(_MapPrivacy.new),
          sharedMapLocationsProvider.overrideWithValue(const {}),
          mapLocationReaderProvider.overrideWithValue(
            () async => (
              const LocationFix(
                latitude: 50.4501,
                longitude: 30.5234,
                accuracyMetres: 12,
              ),
              null,
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            fontFamily: 'MapGolden',
          ),
          home: PeopleMapScreen(
            tileProvider: NetworkTileProvider(
              cachingProvider: const DisabledMapCachingProvider(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byKey(const ValueKey('map-own-marker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-own-marker')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('You'), findsOneWidget);
    expect(
      find.text('Your position is visible on this device'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
