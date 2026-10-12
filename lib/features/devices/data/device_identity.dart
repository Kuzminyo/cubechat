import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/transport/own_device_notice.dart';

/// This device's own id and name among the devices of its account.
///
/// Kept in the secure store, **not in Hive**: a backup and the transfer onto a
/// computer carry Hive across, and a copy of the account must be a device of
/// its own, with its own id — not a second phone answering to the first one's.
abstract interface class DeviceIdentityStore {
  /// The id, minted on first use.
  Future<Uint8List> id();

  /// The name the person gave this device, if they gave one.
  Future<String?> name();
  Future<void> setName(String name);

  /// Forget both: after a wipe or a sign-out this is a new device.
  Future<void> wipe();
}

class SecureDeviceIdentityStore implements DeviceIdentityStore {
  SecureDeviceIdentityStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions:
                  IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;
  static const _idKey = 'cubechat.device.id';
  static const _nameKey = 'cubechat.device.name';
  Uint8List? _cached;

  @override
  Future<Uint8List> id() async {
    final cached = _cached;
    if (cached != null) return cached;
    final stored = await _storage.read(key: _idKey);
    if (stored != null && stored.length == 32) {
      return _cached = _fromHex(stored);
    }
    final random = Random.secure();
    final fresh = Uint8List.fromList(
      List.generate(OwnDeviceNotice.idLen, (_) => random.nextInt(256)),
    );
    await _storage.write(key: _idKey, value: deviceIdHex(fresh));
    return _cached = fresh;
  }

  @override
  Future<String?> name() => _storage.read(key: _nameKey);

  @override
  Future<void> setName(String name) =>
      _storage.write(key: _nameKey, value: name);

  @override
  Future<void> wipe() async {
    _cached = null;
    for (final key in [_idKey, _nameKey]) {
      try {
        await _storage.delete(key: key);
      } catch (_) {}
    }
  }

  static Uint8List _fromHex(String hex) => Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
}

String deviceIdHex(Uint8List id) =>
    id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// What this build runs on, for the list.
DevicePlatform get currentDevicePlatform {
  if (kIsWeb) return DevicePlatform.unknown;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => DevicePlatform.android,
    TargetPlatform.iOS => DevicePlatform.ios,
    TargetPlatform.windows => DevicePlatform.windows,
    TargetPlatform.macOS => DevicePlatform.macos,
    TargetPlatform.linux => DevicePlatform.linux,
    _ => DevicePlatform.unknown,
  };
}

/// The name a device goes by until the person gives it one. A computer adds
/// its own name, which is what tells two of them apart; a phone's hostname is
/// "localhost" and says nothing.
String defaultDeviceName(DevicePlatform platform) {
  String host() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return '';
    }
  }

  final label = switch (platform) {
    DevicePlatform.android => 'Android',
    DevicePlatform.ios => 'iPhone',
    DevicePlatform.windows => 'Windows',
    DevicePlatform.macos => 'Mac',
    DevicePlatform.linux => 'Linux',
    DevicePlatform.unknown => 'CubeChat',
  };
  final desktop = platform == DevicePlatform.windows ||
      platform == DevicePlatform.macos ||
      platform == DevicePlatform.linux;
  final name = desktop ? host() : '';
  return name.isEmpty ? label : '$label · $name';
}
