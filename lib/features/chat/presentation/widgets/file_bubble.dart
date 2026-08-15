import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../core/util/debug_log.dart';
import '../../../../core/util/open_in.dart';
import '../../../../core/util/share_anchor.dart';
import '../../../../core/utils/file_mime.dart';
import '../../../../core/utils/file_signature.dart';
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

  /// A temporary duplicate of [path] under a name the system can route, or
  /// null when the file already has one (or when nothing can name it).
  ///
  /// The extension is taken from what the sender called the file, then from
  /// the bytes themselves, then from the MIME for the formats no signature can
  /// identify — a text file is just text, and there is nothing in it to read.
  Future<String?> _openableCopy(String path, String mime) async {
    try {
      String? extension = _extensionOf(message.fileName) ?? _extensionOf(path);
      if (extension == null) {
        final file = File(path);
        final length = await file.length();
        if (length > 0) {
          final header = await file.openRead(0, length < 32 ? length : 32).first;
          extension = extensionFromSignature(Uint8List.fromList(header));
        }
      }
      extension ??= switch (mime) {
        'text/plain' => 'txt',
        'text/markdown' => 'md',
        'text/csv' => 'csv',
        'text/html' => 'html',
        'text/xml' || 'application/xml' => 'xml',
        'application/json' => 'json',
        'text/vcard' => 'vcf',
        'text/calendar' => 'ics',
        _ => null,
      };
      if (extension == null) return null;
      if (path.toLowerCase().endsWith('.${extension.toLowerCase()}'))
        return null;

      final dir = Directory('${(await getTemporaryDirectory()).path}'
          '${Platform.pathSeparator}open');
      await dir.create(recursive: true);
      // Named after the file rather than after its id: this name is what the
      // opening app shows in its title bar, and "3f9c1a…" is not a file name
      // anybody recognises as theirs.
      final stem = _stemOf(message.fileName ?? path);
      final target = '${dir.path}${Platform.pathSeparator}$stem.$extension';
      await File(path).copy(target);
      return target;
    } catch (e) {
      DebugLog.instance.log('FILE', 'openable copy failed for $path: $e');
      return null;
    }
  }

  /// The extension of [name], or null when there is nothing usable — no dot, a
  /// trailing dot, or something too long to be one (a dot in a date, say).
  static String? _extensionOf(String? name) {
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    final extension = name.substring(dot + 1);
    if (extension.length > 5 || extension.contains(Platform.pathSeparator)) {
      return null;
    }
    return RegExp(r'^[A-Za-z0-9]+$').hasMatch(extension) ? extension : null;
  }

  static String _stemOf(String nameOrPath) {
    final name = nameOrPath.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final cleaned = stem.replaceAll(RegExp(r'[^A-Za-z0-9 _.-]'), '_').trim();
    if (cleaned.isEmpty) return 'file';
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
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

    // Preview first, on both platforms.
    //
    // iOS used to go straight to the "Open in…" menu on a tap, on the reasoning
    // that a document belongs in the app that reads documents. What that menu
    // actually is, though, is a list of apps to copy the file *into* — so a tap
    // meaning "what is this?" answered with "who should get this?", and a
    // tester reported it, accurately, as the app wanting to forward his file
    // instead of opening it. He was right: nothing about that screen opens
    // anything.
    //
    // So the tap previews (QuickLook on iOS, the registered handler on
    // Android), which is what every messenger does and what the gesture is
    // asking for. Handing the file to another app is still available — it moved
    // one level down, to the offer below, where it is a deliberate choice
    // rather than the answer to a tap.
    OpenResult? result;
    try {
      // A type we cannot name is passed as *no* type rather than as
      // octet-stream: asked to open "some bytes", Android looks for an app
      // that claims to handle anything, finds none, and says the file cannot
      // be opened. Given nothing, it resolves the extension itself.
      final declared = isUnknownMime(mime) ? null : mime;
      result = await OpenFilex.open(path, type: declared);

      // Ask again without the type before giving up.
      //
      // The type we hand over is the sender's, and it only has to be slightly
      // wrong to match nothing: a screenshot announced as `image/png` by a
      // phone that files screenshots under a vendor type, an office document
      // whose long OOXML string one ROM spells differently, a PDF from an app
      // that said `application/x-pdf`. Android then reports, accurately and
      // uselessly, that no installed app opens *that* type — while the very
      // same file opens fine if it is left to read the extension itself.
      //
      // Testers hit this on a PNG and a PDF, which are the two types every
      // phone can open, which is what makes the answer so obviously wrong.
      if (declared != null && result.type != ResultType.done) {
        DebugLog.instance.log(
            'FILE', 'open as $declared gave ${result.type} — retrying untyped');
        result = await OpenFilex.open(path);
      }

      // Third and last: give the file a name the system can read.
      //
      // This is what old attachments need. A build from before any of this
      // stored them under an id with no extension and frequently no MIME
      // either, so the two attempts above ask Android to route "some bytes at
      // a path ending in nothing" — which resolves to no handler on any phone,
      // and is exactly the "no app opens this file" a tester photographed on a
      // screenshot every phone can open.
      //
      // Nothing is renamed in place: the conversation's copy is what the
      // transfer centre and the re-request path both address, so this hands
      // the opener a temporary duplicate under a better name instead.
      if (result.type != ResultType.done) {
        final copy = await _openableCopy(path, mime);
        if (copy != null) {
          DebugLog.instance.log('FILE', 'retrying via $copy');
          result = await OpenFilex.open(copy);
        }
      }
    } catch (e) {
      // Falls through to the share offer below rather than stopping here.
      //
      // It used to toast and return, which made a plugin that failed to
      // register — `MissingPluginException on channel open_file`, seen in the
      // field and intermittent — into a file that simply could not be opened
      // by any route. The sheet is a different plugin and works regardless, so
      // the way out that already exists for "nothing handles this type" is the
      // right answer for "the opener itself is missing" too.
      DebugLog.instance.log('FILE', 'open failed for $path: $e');
    }
    if (result?.type == ResultType.done || !context.mounted) return;
    if (result != null) {
      DebugLog.instance
          .log('FILE', 'open $path ($mime): ${result.type} ${result.message}');
    }

    if (sharingRestricted) {
      // No offer to share instead: that is the one route this setting exists
      // to close. Say why, rather than leaving a tap that appears to do
      // nothing.
      showGlassToast(context, t.contactProfileCopyingRestricted);
      return;
    }

    // Nothing here could preview it. On iOS the "Open in…" menu is the other
    // route to an app that can — it copies the file across and launches it —
    // so it is offered now, having lost its claim on the plain tap.
    if (OpenIn.isSupported) {
      if (await OpenIn.handOff(path, anchor: shareAnchorFor(context))) return;
      if (!context.mounted) return;
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
    if (share != true || !context.mounted) return;
    await Share.shareXFiles(
      [XFile(path)],
      subject: message.fileName,
      // Not optional: without a non-empty anchor iOS raises rather than
      // opening the sheet, on iPhone as much as on iPad. See [shareAnchorFor].
      sharePositionOrigin: shareAnchorFor(context),
    );
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
      'pdf' => Icons.picture_as_pdf_rounded,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_rounded,
      'doc' || 'docx' || 'odt' || 'rtf' || 'txt' => Icons.description_rounded,
      'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_rounded,
      'ppt' || 'pptx' || 'odp' => Icons.slideshow_rounded,
      'mp3' || 'wav' || 'flac' || 'ogg' || 'm4a' => Icons.audiotrack_rounded,
      'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' => Icons.movie_rounded,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'webp' ||
      'heic' =>
        Icons.image_rounded,
      'apk' => Icons.install_mobile_rounded,
      _ => Icons.insert_drive_file_rounded,
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
