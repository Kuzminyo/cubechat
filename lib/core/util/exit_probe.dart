import 'package:flutter/services.dart';

import 'debug_log.dart';

/// How the previous run ended, asked of Android once per launch.
///
/// A crash takes the in-memory log with it, so without this the log a tester
/// sends after "it closed when I tapped translate" begins at the next launch
/// and says nothing about the fall. The native side (`ExitRecorder.kt`) keeps
/// the JVM stack trace of an uncaught exception and reads Android's own record
/// of how the process exited, which also covers native crashes and ANRs.
/// Each exit is reported once.
class ExitProbe {
  const ExitProbe._();

  static const _channel = MethodChannel('cubechat/exit_recorder');

  static Future<void> logPreviousExits() async {
    try {
      final exits = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'lastExits',
      );
      if (exits == null) return;
      for (final exit in exits) {
        final at = exit['at'];
        final when = at is int && at > 0
            ? DateTime.fromMillisecondsSinceEpoch(at).toIso8601String()
            : 'unknown time';
        final description = (exit['description'] as String?)?.trim() ?? '';
        DebugLog.instance.log(
          'CRASH',
          'previous run ended: ${exit['reason']} at $when'
              '${description.isEmpty ? '' : '\n$description'}',
        );
      }
    } on MissingPluginException {
      // iOS, desktop, tests: nothing to ask.
    } catch (e) {
      DebugLog.instance.log('CRASH', 'exit probe failed: $e');
    }
  }
}
