import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'debug_log.dart';

/// How an attempt to install an update went, as far as this side can tell.
enum SelfUpdateOutcome {
  /// The system is asking to confirm, or already installing.
  started,

  /// "Install unknown apps" is off for cubechat; its settings page was opened.
  needsPermission,

  /// Nothing was picked.
  cancelled,

  /// The file is not an APK, or is another app's.
  notOurs,

  /// The installer refused it or the user declined; see [SelfUpdate.lastError].
  failed,
}

/// Install an update of cubechat from an APK file, keeping lock-screen calls.
///
/// Android only — see `SelfUpdater.kt` for why this exists: the phone's own
/// installer switches off full-screen calls on every sideloaded update, and
/// an APK cubechat installs itself keeps them on.
class SelfUpdate {
  const SelfUpdate._();

  static const _channel = MethodChannel('cubechat/self_update');

  /// The installer's message for the last failure, if any.
  static String? lastError;

  /// [onFailure] hears a refusal or a "cancel" in the system dialog, which
  /// arrive after [pickAndInstall] has returned. Success replaces this
  /// process and is never heard from.
  static Future<SelfUpdateOutcome> pickAndInstall({
    void Function(String error)? onFailure,
  }) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'status') return;
      final args = call.arguments as Map<Object?, Object?>?;
      final message = args?['message'] as String?;
      final status = args?['status'];
      DebugLog.instance
          .log('UPDATE', 'installer status $status: ${message ?? ''}');
      lastError = message ?? 'status $status';
      onFailure?.call(lastError!);
    });
    final allowed = await _channel.invokeMethod<bool>('canInstall') ?? false;
    if (!allowed) {
      await _channel.invokeMethod<bool>('openInstallSettings');
      return SelfUpdateOutcome.needsPermission;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['apk'],
    );
    final path = picked?.files.single.path;
    if (path == null) return SelfUpdateOutcome.cancelled;

    final started = await _channel.invokeMethod<String>('install', {'path': path});
    DebugLog.instance.log('UPDATE', 'install from file: $started');
    switch (started) {
      case 'started':
        return SelfUpdateOutcome.started;
      case 'not_an_apk':
      case 'other_app':
        return SelfUpdateOutcome.notOurs;
      default:
        lastError = started;
        return SelfUpdateOutcome.failed;
    }
  }
}
