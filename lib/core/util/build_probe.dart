import 'package:flutter/services.dart';

import 'debug_log.dart';

/// Facts about the build a phone is actually running, asked of the native side.
///
/// Two of them, and both exist because the map failed silently for an evening.
/// The Maps key is baked in at build time from a file deliberately kept out of
/// the repository, so the same source produced builds with a key, builds with
/// none, and builds carrying a key valid only for the other platform. And a key
/// restricted to an iOS app is matched against the bundle identifier of the
/// *installed* app, which sideloading tools rewrite when they re-sign — so the
/// id compiled in is not necessarily the id being checked.
///
/// Every one of those failures looks the same from the phone: markers drawn on
/// a grey sheet, and not a word anywhere. Four characters of the key and the
/// bundle id name the suspect. Four characters are enough to tell two keys
/// apart and useless to anyone reading the log over somebody's shoulder.
class BuildProbe {
  const BuildProbe._();

  static const _channel = MethodChannel('cubechat/build_info');

  /// Write what this install is into the debug log.
  ///
  /// Best-effort by design: a platform with no handler simply says so, and
  /// nothing about startup depends on the answer.
  static Future<void> logBuildFacts() async {
    try {
      final facts = await _channel.invokeMapMethod<String, dynamic>('buildFacts');
      if (facts == null) {
        DebugLog.instance.log('BUILD', 'native side returned nothing');
        return;
      }
      DebugLog.instance.log(
          'BUILD',
          'installed as ${facts['bundleId']}, '
              'maps key ends with ${facts['mapsKeyTail']}');
    } on MissingPluginException {
      DebugLog.instance.log('BUILD', 'no native build-facts handler here');
    } catch (e) {
      DebugLog.instance.log('BUILD', 'build-facts probe failed: $e');
    }
  }
}
