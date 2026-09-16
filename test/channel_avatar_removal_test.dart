import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/channels/data/channel_avatars_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// A room's picture, removed, came back — reported as "в каналах не
/// прибирається аватарка".
///
/// The clear itself always worked. What undid it was the holding area: a frame
/// from a sender the roster could not yet vouch for is parked until it can, and
/// a picture parked before the clear was replayed after it, restoring exactly
/// what the administrator had just taken down. Anything applied now is newer
/// than anything still waiting, so applying drops the held frame.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_chan_avatar_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    try {
      await Hive.close();
    } on FileSystemException {
      // Windows holds the encrypted box briefly after close.
    }
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Same.
    }
  });

  test('clearing a room picture forgets one held from before the clear',
      () async {
    final container = ProviderContainer(
      overrides: [
        messagingServiceProvider.overrideWith((ref) {
          final service = MessagingService(ref);
          ref.onDispose(() => unawaited(service.dispose()));
          return service;
        }),
      ],
    );
    addTearDown(container.dispose);
    final service = container.read(messagingServiceProvider);

    // A picture from somebody the roster cannot vouch for yet.
    service.debugHoldChannelState(
      '#room',
      InnerPayloadType.channelAvatar,
      'a1b2c3d4e5f60718',
      Uint8List.fromList(const [1, 2, 3]),
    );
    expect(service.debugHeldChannelState, contains('#room|channelAvatar'));

    // The administrator takes the picture down: an empty body is the clear.
    await service.debugApplyChannelState(
      '#room',
      InnerPayloadType.channelAvatar,
      Uint8List(0),
    );

    expect(
      service.debugHeldChannelState,
      isNot(contains('#room|channelAvatar')),
      reason: 'a confirmed sender must not put the old picture back',
    );
    expect(
      container.read(channelAvatarsControllerProvider.notifier)
          .forChannel('#room'),
      isNull,
    );
  });
}
