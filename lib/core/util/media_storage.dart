import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where conversation media lives on disk.
///
/// **Not the cache directory.** Photos, voice notes and files are the
/// conversation — there is no server holding a second copy, so a picture the
/// OS evicts is a picture gone for good, and the bubble that pointed at it
/// becomes a permanent dead end.
///
/// That is exactly what was happening: received images, received voice notes,
/// your own recordings and your own sent photos all went to
/// `getApplicationCacheDirectory()`, which Android and iOS are free to empty
/// whenever they want space — typically within a day or two. Received *files*
/// were always kept under Documents, which is why those survived while
/// everything else quietly stopped opening.
///
/// Documents rather than Support, to match the inbox and outbox that were
/// already there, so there is one place for all of it.
Future<Directory> mediaDirectory(String name) async {
  final root = await getApplicationDocumentsDirectory();
  final dir = Directory('${root.path}${Platform.pathSeparator}$name');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// Received photos.
Future<Directory> receivedImagesDirectory() =>
    mediaDirectory('cubechat-images');

/// Voice notes — both the ones that arrive and the ones recorded here. They
/// share a directory because they are the same kind of thing and are named by
/// a unique id either way.
Future<Directory> voiceDirectory() => mediaDirectory('cubechat-audio');

/// Copies of photos sent from this device, so an outgoing bubble has something
/// to render.
Future<Directory> sentImagesDirectory() => mediaDirectory('cubechat-sent');
