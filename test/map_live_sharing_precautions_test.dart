import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/core/util/location_service.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/map/data/map_friends_controller.dart';
import 'package:cubechat/features/map/data/map_presence_controller.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the live map does about the precautions App Store review asked for
/// under guideline 5.1.2(i), besides asking first (see
/// map_sharing_consent_test.dart): a blocked user is not shown your location,
/// blocking takes it back at once, and hiding takes it back from everybody.
class _Privacy extends PrivacySettingsController {
  _Privacy(this.sharing);
  final bool sharing;
  @override
  PrivacySettings build() =>
      PrivacySettings.initial.copyWith(shareMapLocation: sharing);
  @override
  Future<void> setShareMapLocation(bool value) async {
    state = state.copyWith(shareMapLocation: value);
  }
}

class _Friends extends MapFriendsController {
  _Friends(this.friends);
  final Set<String> friends;
  @override
  Set<String> build() => friends;
}

class _Peers extends KnownPeersController {
  _Peers(this.peers);
  Map<String, KnownPeer> peers;
  @override
  Map<String, KnownPeer> build() => peers;
  void replace(Map<String, KnownPeer> next) => state = next;
}

class _Messaging extends Fake implements MessagingService {
  final sent = <(String, SharedLocation)>[];
  @override
  Future<Message> sendText(
    String chatId,
    String text, {
    String? replyToWireId,
    String? replyPreview,
    bool transient = false,
    Message? resendOf,
  }) async {
    sent.add((chatId, SharedLocation.tryParse(text)!));
    return Message(
      id: 'm${sent.length}',
      chatId: chatId,
      text: text,
      sentAt: DateTime.now(),
      isMine: true,
      route: MessageRoute.internet,
    );
  }
}

KnownPeer _peer(String id, {bool blocked = false}) => KnownPeer(
      pubkeyHex: id,
      displayName: id,
      lastSeen: DateTime(2026),
      blockedAt: blocked ? DateTime(2026) : null,
    );

const _here = LocationFix(latitude: 50.45, longitude: 30.52, accuracyMetres: 8);

/// Let the controller's unawaited sends run.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Messaging messaging;

  ProviderContainer build({
    bool sharing = true,
    Set<String> friends = const {'alice', 'bob'},
    Map<String, KnownPeer>? peers,
  }) {
    messaging = _Messaging();
    final container = ProviderContainer(overrides: [
      privacySettingsProvider.overrideWith(() => _Privacy(sharing)),
      mapFriendsControllerProvider.overrideWith(() => _Friends(friends)),
      knownPeersControllerProvider.overrideWith(
        () => _Peers(peers ?? {for (final id in friends) id: _peer(id)}),
      ),
      messagingServiceProvider.overrideWithValue(messaging),
    ]);
    addTearDown(container.dispose);
    // A position already in hand, so no beacon has to ask a GPS this test
    // does not have.
    container.read(lastLocationFixProvider.notifier).state =
        StampedLocationFix(_here, DateTime.now());
    return container;
  }

  test('a blocked map friend is sent nothing', () async {
    final container = build(peers: {
      'alice': _peer('alice'),
      'bob': _peer('bob', blocked: true),
    });
    container.read(mapPresenceControllerProvider);
    await _settle();

    expect(messaging.sent.map((s) => s.$1).toSet(), {'alice'});
    expect(messaging.sent.every((s) => !s.$2.retraction), isTrue);
  });

  test('with every friend blocked, nothing is sent at all', () async {
    final container = build(peers: {
      'alice': _peer('alice', blocked: true),
      'bob': _peer('bob', blocked: true),
    });
    container.read(mapPresenceControllerProvider);
    await _settle();

    expect(messaging.sent, isEmpty);
  });

  test('blocking a friend takes the pin back from them at once', () async {
    final container = build();
    container.read(mapPresenceControllerProvider);
    await _settle();
    expect(messaging.sent.map((s) => s.$1).toSet(), {'alice', 'bob'});
    messaging.sent.clear();

    (container.read(knownPeersControllerProvider.notifier) as _Peers).replace({
      'alice': _peer('alice'),
      'bob': _peer('bob', blocked: true),
    });
    await _settle();

    final toBob = messaging.sent.where((s) => s.$1 == 'bob').toList();
    expect(toBob, isNotEmpty, reason: 'the blocked friend is told to drop us');
    expect(toBob.every((s) => s.$2.retraction), isTrue,
        reason: 'and is never sent a position again');
  });

  test('hiding takes the pin back from every friend', () async {
    final container = build();
    container.read(mapPresenceControllerProvider);
    await _settle();
    messaging.sent.clear();

    await container
        .read(privacySettingsProvider.notifier)
        .setShareMapLocation(false);
    await _settle();

    expect(
      messaging.sent.where((s) => s.$2.retraction).map((s) => s.$1).toSet(),
      {'alice', 'bob'},
    );
    expect(messaging.sent.where((s) => !s.$2.retraction), isEmpty);
  });

  test('sharing that was never allowed sends nothing', () async {
    final container = build(sharing: false);
    container.read(mapPresenceControllerProvider);
    await _settle();

    expect(messaging.sent, isEmpty);
  });
}
