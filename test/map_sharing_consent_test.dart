import 'dart:typed_data';

import 'package:cubechat/core/identity/avatar_controller.dart';
import 'package:cubechat/core/identity/nickname_controller.dart';
import 'package:cubechat/core/util/location_service.dart';
import 'package:cubechat/features/map/data/map_friends_controller.dart';
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
import 'package:flutter_test/flutter_test.dart';

/// The screen App Store review looks at for guideline 5.1.2(i): "request
/// permission to display location on a map, with the option to decline".
///
/// Show me on the map asks first. "Don't allow" leaves sharing off and the
/// phone not even asked where it is; "Allow" turns sharing on, and Hide turns
/// it off again in one tap with no question.
class _Peers extends KnownPeersController {
  @override
  Map<String, KnownPeer> build() => const {};
}

class _Friends extends MapFriendsController {
  @override
  Set<String> build() => const {};
}

class _Privacy extends PrivacySettingsController {
  @override
  PrivacySettings build() =>
      PrivacySettings.initial.copyWith(shareMapLocation: false);
  @override
  Future<void> setShareMapLocation(bool value) async {
    state = state.copyWith(shareMapLocation: value);
  }
}

class _PeerAvatars extends PeerAvatarsController {
  @override
  Map<String, Uint8List> build() => const {};
}

class _Avatar extends AvatarController {
  @override
  Uint8List? build() => null;
}

class _Nickname extends NicknameController {
  @override
  String build() => 'You';
}

void main() {
  testWidgets('Show me asks first; declining leaves the phone unasked',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var fixes = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knownPeersControllerProvider.overrideWith(_Peers.new),
          mapFriendsControllerProvider.overrideWith(_Friends.new),
          privacySettingsProvider.overrideWith(_Privacy.new),
          peerAvatarsControllerProvider.overrideWith(_PeerAvatars.new),
          avatarProvider.overrideWith(_Avatar.new),
          nicknameControllerProvider.overrideWith(_Nickname.new),
          sharedMapLocationsProvider.overrideWithValue(const {}),
          mapLocationReaderProvider.overrideWithValue(() async {
            fixes++;
            return (
              const LocationFix(
                latitude: 50.4501,
                longitude: 30.5234,
                accuracyMetres: 12,
              ),
              null,
            );
          }),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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
    final screen = tester.element(find.byType(PeopleMapScreen));
    final t = AppLocalizations.of(screen);
    final container = ProviderScope.containerOf(screen);

    expect(fixes, 0, reason: 'a hidden person is not located');
    expect(find.byKey(const ValueKey('map-show-me')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('map-show-me')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(t.mapShareConsentTitle), findsOneWidget);

    await tester.tap(find.text(t.mapShareConsentDecline));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(t.mapShareConsentTitle), findsNothing);
    expect(container.read(privacySettingsProvider).shareMapLocation, isFalse);
    expect(fixes, 0, reason: 'a "no" must not so much as read a position');
    expect(find.byKey(const ValueKey('map-show-me')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('map-show-me')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(t.mapShareConsentAllow));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(privacySettingsProvider).shareMapLocation, isTrue);
    expect(find.byKey(const ValueKey('map-hide-me')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('map-hide-me')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(t.mapShareConsentTitle), findsNothing,
        reason: 'hiding is never asked about');
    expect(container.read(privacySettingsProvider).shareMapLocation, isFalse);
    expect(find.byKey(const ValueKey('map-show-me')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
