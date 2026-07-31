import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/glass_toast.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/message.dart';

/// A file attachment in the conversation: icon, name, size.
///
/// Deliberately not a preview. cubechat has no idea what most of these are,
/// and a bubble that tries to render an unknown file either guesses wrong or
/// hands attacker-supplied bytes to a decoder it did not choose. The name and
/// the size are what the recipient needs to decide whether to open it, and
/// opening is left to the system's own share sheet — where the choice of app,
/// and the permission that comes with it, is the user's.
class FileBubble extends StatelessWidget {
  const FileBubble({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = message.fileName ?? 'file';
    final size = message.fileBytes;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _open(context),
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

  Future<void> _open(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final path = message.filePath;
    if (path == null || !await File(path).exists()) {
      if (context.mounted) showGlassToast(context, t.fileMissing);
      return;
    }
    // Handed to the system sheet rather than opened directly: which app gets
    // to read this, and whether it gets to at all, is the user's call.
    await Share.shareXFiles([XFile(path)], subject: message.fileName);
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
