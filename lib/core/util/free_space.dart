import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Free bytes on the volume the app keeps its files on.
///
/// AirDrop asks before it shows a request: a transfer that would fill the
/// phone is declined up front with "not enough space" rather than failing
/// half way. Null when the platform does not say — and unknown is not "full".
abstract final class FreeSpace {
  static const MethodChannel _channel = MethodChannel('cubechat/storage');

  static Future<int?> bytes() async {
    try {
      return await _channel.invokeMethod<int>('freeBytes');
    } catch (_) {
      return null;
    }
  }
}

final freeSpaceProvider =
    Provider<Future<int?> Function()>((ref) => FreeSpace.bytes);
