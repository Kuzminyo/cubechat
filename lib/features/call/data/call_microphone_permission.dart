import 'package:permission_handler/permission_handler.dart';
import '../../../core/util/debug_log.dart';

/// Read system permission for every attempt, including after returning from
/// Settings. The iOS pod must compile PERMISSION_MICROPHONE=1.
Future<bool> requestCallMicrophonePermission({
  Future<PermissionStatus> Function()? check,
  Future<PermissionStatus> Function()? request,
}) async {
  final before = await (check ?? () => Permission.microphone.status)();
  DebugLog.instance.log('CALL', 'microphone permission before: ${before.name}');
  if (before.isGranted) return true;
  final after = await (request ?? () => Permission.microphone.request())();
  DebugLog.instance.log('CALL', 'microphone permission after: ${after.name}');
  return after.isGranted;
}
