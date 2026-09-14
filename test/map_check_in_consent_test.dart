import 'dart:typed_data';

import 'package:cubechat/core/identity/avatar_controller.dart';
import 'package:cubechat/core/identity/nickname_controller.dart';
import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/core/util/location_service.dart';
import 'package:cubechat/features/map/data/map_friends_controller.dart';
import 'package:cubechat/features/map/data/map_presence_controller.dart';
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

/// The one screen App Store review looks at for guideline 5.1.2(i): "request
/// permission to display location on a map, with the option to decline".
///
/// `map_check_in_test.dart` pins the controller. This pins the part a reviewer
/// actually touches — that the first tap on Check in asks, that "Don't allow"
/// means the phone is not even asked where it is, and that nothing reaches a
/// friend until the person says yes.
const _alice =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _Peers extends KnownPeersController {
  @override
  Map<String, KnownPeer> build() => {
        _alice: KnownPeer(
          pubkeyHex: _alice,
          displayName: 'Alice',
          lastSeen: DateTime(2026),
        ),
      };
}

class _Friends extends MapFriendsController {
  @override
  Set<String> build() => {_alice};
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
  testWidgets('declining never locates the phone; allowing checks in once',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var fixes = 0;
    final sent = <(String, SharedLocation)>[];

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
          mapBeaconSenderProvider.overrideWithValue((peerId, text) async {
            sent.add((peerId, SharedLocation.tryParse(text)!));
            return true;
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
    final t = AppLocalizations.of(
      tester.element(find.byType(PeopleMapScreen)),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PeopleMapScreen)),
    );

    expect(fixes, 0, reason: 'opening the map asks the phone nothing');

    await tester.tap(find.byKey(const ValueKey('map-check-in')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(t.mapCheckInConsentTitle), findsOneWidget);

    await tester.tap(find.text(t.mapCheckInDecline));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(t.mapCheckInConsentTitle), findsNothing);
    expect(container.read(privacySettingsProvider).shareMapLocation, isFalse);
    expect(fixes, 0, reason: 'a "no" must not so much as read a position');
    expect(sent, isEmpty);
    expect(find.byKey(const ValueKey('map-check-in')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('map-check-in')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(t.mapCheckInAllow));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(privacySettingsProvider).shareMapLocation, isTrue);
    expect(sent, hasLength(1));
    expect(sent.single.$1, _alice);
    expect(sent.single.$2.presence, isTrue);
    expect(container.read(mapPresenceControllerProvider), isNotNull);
    expect(find.byKey(const ValueKey('map-checked-in')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
