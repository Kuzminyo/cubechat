import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../core/util/debug_log.dart';
import '../../../../core/utils/file_mime.dart';
import '../../../../core/widgets/glass_toast.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/message.dart';

/// A file attachment in the conversation: icon, name, size.
///
/// Deliberately not a preview. cubechat has no idea what most of these are,
/// and a bubble that tries to render an unknown file either guesses wrong or
/// hands attacker-supplied bytes to a decoder it did not choose. The name and
/// the size are what the recipient needs to decide whether to open it, and
/// opening is left to the system — which resolves the handler, and asks when
/// more than one app claims the type, so the choice of app and the permission
/// that comes with it stay the user's.
class FileBubble extends ConsumerWidget {
  const FileBubble({
    super.key,
    required this.message,
    this.onLongPress,
    this.sharingRestricted = false,
  });

  final Message message;
  final VoidCallback? onLongPress;

  /// When the conversation forbids copying, the file still opens — reading it
  /// is the point of having received it — but the hand-off to another app is
  /// withheld, because that is the step that takes it out of here.
  final bool sharingRestricted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final name = message.fileName ?? 'file';
    final size = message.fileBytes;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _open(context, ref),
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.brandPrimary.withValues(alpha: 0.16),
                border: Border.all(
                  color: AppColors.brandPrimary.withValues(alpha: 0.38),
                ),
              ),
              child: Icon(
                _iconFor(name),
                size: 19,
                color: AppColors.brandPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 14,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    size == null ? t.fileOpenHint : formatBytes(size),
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    final path = message.filePath;
    if (path == null || !await File(path).exists()) {
      DebugLog.instance.log('FILE', 'open: nothing at ${path ?? "(no path)"}');
      // Gone from disk — cleared in the transfer centre, most likely. Nobody
      // else has a copy except the person who sent it, so ask them; the answer
      // lands under the same id and this bubble picks it up.
      final asked = await _requestAgain(ref);
      if (!context.mounted) return;
      showGlassToast(context, asked ? t.fileRequestedAgain : t.fileMissing);
      return;
    }

    // Tapping a received file used to hand it straight to the share sheet,
    // which answers "who else should get this?" — not "what is it?", which is
    // what a tap is asking. Open it; the OS resolves the handler (and asks,
    // when more than one claims the type). Sharing is still available, one
    // level down, for when passing it on really is the intent.
    final mime = fileMimeType(
      message.fileName ?? path,
      declaredMime: message.text,
    );
    final OpenResult result;
    try {
      // A type we cannot name is passed as *no* type rather than as
      // octet-stream: asked to open "some bytes", Android looks for an app
      // that claims to handle anything, finds none, and says the file cannot
      // be opened. Given nothing, it resolves the extension itself.
      result = await OpenFilex.open(
        path,
        type: isUnknownMime(mime) ? null : mime,
      );
    } catch (e) {
      // Without this the tap did nothing at all: a throw inside an async
      // handler goes to the zone, and the finger gets no answer either way.
      DebugLog.instance.log('FILE', 'open failed for $path: $e');
      if (context.mounted) showGlassToast(context, t.fileOpenFailed);
      return;
    }
    if (result.type == ResultType.done || !context.mounted) return;
    DebugLog.instance
        .log('FILE', 'open $path ($mime): ${result.type} ${result.message}');

    if (sharingRestricted) {
      // No offer to share instead: that is the one route this setting exists
      // to close. Say why, rather than leaving a tap that appears to do
      // nothing.
      showGlassToast(context, t.contactProfileCopyingRestricted);
      return;
    }

    // No installed app claims this type — offer the sheet as the way out
    // rather than a dead end.
    final share = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.glass(0.15)),
        ),
        title: Text(
          t.fileNoHandlerTitle,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          t.fileNoHandlerHint,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel,
                style: TextStyle(color: AppColors.textOnGlassDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.fileShareAction,
                style: TextStyle(color: AppColors.brandPrimary)),
          ),
        ],
      ),
    );
    if (share != true) return;
    await Share.shareXFiles([XFile(path)], subject: message.fileName);
  }

  /// Ask the sender for the bytes again.
  ///
  /// Only for a file somebody sent *us*: our own outgoing copy vanishing means
  /// we deleted it, and there is nobody to ask. Returns whether the request
  /// actually went out, so the toast can say what happened rather than guess.
  Future<bool> _requestAgain(WidgetRef ref) async {
    final wireId = message.wireId;
    if (message.isMine || wireId == null) return false;
    return ref
        .read(messagingServiceProvider)
        .requestMediaAgain(message.chatId, wireId);
  }

  /// A hint at the kind of thing, from the extension. Only a hint — the
  /// extension is chosen by the sender and proves nothing about the contents.
  static IconData _iconFor(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
      'doc' || 'docx' || 'odt' || 'rtf' || 'txt' => Icons.description_outlined,
      'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_outlined,
      'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
      'mp3' || 'wav' || 'flac' || 'ogg' || 'm4a' => Icons.audiotrack_outlined,
      'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' => Icons.movie_outlined,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'webp' ||
      'heic' =>
        Icons.image_outlined,
      'apk' => Icons.android_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

/// Human-readable byte count. Binary units, because that is what a file
/// manager on either platform shows and a mismatch reads as a bug.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal below ten, none above: "9.4 MB" is useful, "94.3 MB" is noise.
  final text = value < 10 ? value.toStringAsFixed(1) : value.round().toString();
  return '$text ${units[unit]}';
}
