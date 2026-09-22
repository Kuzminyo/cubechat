import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;

String _airdropPath(Directory docs) =>
    '${docs.path}${Platform.pathSeparator}airdrop';

/// Where received AirDrop files live: the app's own documents, in a folder of
/// their own. Backup and phone transfer take the `cubechat-*` folders only, so
/// these never leave the phone — as the design says.
Future<Directory> airdropDirectory() async {
  final dir = Directory(_airdropPath(await getApplicationDocumentsDirectory()));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Injected so tests keep their files in a temporary directory.
final airdropDirectoryProvider =
    Provider<Future<Directory> Function()>((ref) => airdropDirectory);

/// A free place for [rawName] in [dir]: the sanitised name, or the same with
/// " (1)", " (2)"… before the extension.
Future<File> uniqueFileIn(Directory dir, String rawName) async {
  final safe = safeFileName(rawName);
  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  final sep = Platform.pathSeparator;
  var candidate = File('${dir.path}$sep$safe');
  for (var n = 1; await candidate.exists(); n++) {
    candidate = File('${dir.path}$sep$stem ($n)$ext');
  }
  return candidate;
}

/// Emergency wipe: the whole folder, best effort.
Future<void> deleteAirdropDirectory() async {
  try {
    final dir =
        Directory(_airdropPath(await getApplicationDocumentsDirectory()));
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {
    // A wipe that cannot find the folder has nothing to wipe.
  }
}
