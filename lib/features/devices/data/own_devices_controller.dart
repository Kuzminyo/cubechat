import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/avatar_controller.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/identity/own_profile_edits.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/debug_log.dart';
import 'device_identity.dart';
import 'own_devices.dart';
import 'own_profile_sync.dart';

/// This device's id and name. A provider so the wipe can forget them and a
/// test can stand in for the secure store.
final deviceIdentityStoreProvider =
    Provider<DeviceIdentityStore>((_) => SecureDeviceIdentityStore());

const _knownKey = 'devices.known';

/// The devices of this account. Rebuilt with the messaging service — a wipe
/// replaces that, and with it the stream of notices this listens to.
final ownDevicesProvider = ChangeNotifierProvider<OwnDevicesService>((ref) {
  final messaging = ref.watch(messagingServiceProvider);
  final platform = currentDevicePlatform;
  return OwnDevicesService(
    send: (notice) async {
      final delivery = await messaging.sendOwnDeviceNotice(notice);
      DebugLog.instance.log('DEVICES', 'sent ${notice.kind.name}: $delivery');
    },
    inbound: messaging.ownDeviceNotices,
    store: ref.read(deviceIdentityStoreProvider),
    // In the encrypted settings box. It travels with a backup, which is fine:
    // it is the account's list, and the copy's own id is not in it.
    load: () async {
      try {
        final box = await hiveCipherProvider
            .openEncryptedBox<dynamic>(HiveBoxes.settings);
        final raw = box.get(_knownKey);
        if (raw is! String) return const [];
        final list = jsonDecode(raw);
        if (list is! List) return const [];
        return [
          for (final item in list)
            if (OwnDevice.fromJson(item) case final device?) device,
        ];
      } catch (e) {
        DebugLog.instance.log('DEVICES', 'reading the list failed: $e');
        return const [];
      }
    },
    save: (devices) async {
      try {
        final box = await hiveCipherProvider
            .openEncryptedBox<dynamic>(HiveBoxes.settings);
        await box.put(
          _knownKey,
          jsonEncode([for (final d in devices) d.toJson()]),
        );
      } catch (e) {
        DebugLog.instance.log('DEVICES', 'saving the list failed: $e');
      }
    },
    platform: platform,
    defaultName: defaultDeviceName(platform),
  );
});

const _profileAtKey = 'devices.profileAt';

/// The account's nickname and avatar, kept the same on all of its devices —
/// see [OwnProfileSync]. Rebuilt with the messaging service, like
/// [ownDevicesProvider], and kept alive from `app.dart`.
final ownProfileSyncProvider = Provider<OwnProfileSync>((ref) {
  final messaging = ref.watch(messagingServiceProvider);
  final sync = OwnProfileSync(
    send: (notice) async {
      final delivery = await messaging.sendOwnDeviceNotice(notice);
      return !delivery.isNotSent;
    },
    inbound: messaging.ownDeviceNotices,
    deviceId: ref.read(deviceIdentityStoreProvider).id,
    current: () async {
      await ref.read(nicknameControllerProvider.notifier).loaded;
      await ref.read(avatarProvider.notifier).loaded;
      return OwnProfile(
        nickname: ref.read(nicknameControllerProvider),
        avatar: ref.read(avatarProvider),
      );
    },
    apply: (profile) async {
      await ref
          .read(nicknameControllerProvider.notifier)
          .setFromAnotherDevice(profile.nickname);
      final avatar = ref.read(avatarProvider.notifier);
      final picture = profile.avatar;
      if (picture == null) {
        await avatar.clearFromAnotherDevice();
      } else {
        await avatar.setFromAnotherDevice(picture);
      }
    },
    // In the settings box with the name and the picture, so a backup or a
    // desktop sign-in carries the moment along with what it dates.
    loadStamp: () async {
      try {
        final box = await hiveCipherProvider
            .openEncryptedBox<dynamic>(HiveBoxes.settings);
        final raw = box.get(_profileAtKey);
        return raw is int ? raw : 0;
      } catch (e) {
        DebugLog.instance.log('DEVICES', 'reading the profile moment: $e');
        return 0;
      }
    },
    saveStamp: (stamp) async {
      try {
        final box = await hiveCipherProvider
            .openEncryptedBox<dynamic>(HiveBoxes.settings);
        await box.put(_profileAtKey, stamp);
      } catch (e) {
        DebugLog.instance.log('DEVICES', 'saving the profile moment: $e');
      }
    },
  );
  ref.listen<int>(ownProfileEditsProvider, (_, __) {
    unawaited(sync.edited());
  });
  ref.onDispose(sync.dispose);
  unawaited(sync.start());
  return sync;
});
