import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Opens the platform-approved Bluetooth enable flow.
///
/// Android does not let an app silently switch Bluetooth on. The closest safe
/// equivalent is the system confirmation dialog, which this channel opens and
/// resolves after the user answers it. iOS exposes no equivalent dialog, so it
/// falls back to the app's Settings page.
class BluetoothPower {
  const BluetoothPower({
    this.channel = const MethodChannel('cubechat/bluetooth_power'),
  });

  final MethodChannel channel;

  Future<bool> requestEnable() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.android) {
      await openAppSettings();
      return false;
    }

    try {
      return await channel.invokeMethod<bool>('requestEnable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
