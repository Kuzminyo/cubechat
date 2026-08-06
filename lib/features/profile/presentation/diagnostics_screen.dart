import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/open_in.dart';
import '../../../core/util/share_anchor.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/widgets/glass_toast.dart';

/// In-app diagnostic log viewer. Reads the [DebugLog] singleton and rebuilds
/// whenever a new line is added.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  @override
  void initState() {
    super.initState();
    DebugLog.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    DebugLog.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  String _asText(List<DebugLogEntry> entries) => entries
      .map((e) => '${e.at.toIso8601String().substring(11, 23)}  ${e.text}')
      .join('\n');

  /// The share control lives in the AppBar, so the handler has no context of
  /// its own to measure — hence the key.
  final _shareButtonKey = GlobalKey();

  /// Send the log out as a file rather than through the clipboard.
  ///
  /// Copy-all was the only way out of here, and a connection log is thousands
  /// of lines — too much to paste into a chat, and the part that matters is
  /// never the part that survives the paste. A file goes to the developer
  /// intact, which is the difference between "connection is flaky" and a fix.
  ///
  /// The anchor is what makes the button work at all on iOS. Without a
  /// non-empty `sharePositionOrigin` UIKit refuses to place the popover and
  /// raises — on iPhone, not only iPad — so the tap did nothing whatsoever and
  /// the one screen that exists to get a log off the phone could not. See
  /// [shareAnchorFor]; the failure is now also reported rather than swallowed.
  ///
  /// [OpenIn.handOff] is tried first, and only on iOS, because the point of
  /// this button is to get the file *to somebody*. The share sheet hands it to
  /// the chosen app's extension, which draws over cubechat and never leaves it;
  /// "Open in…" launches the app itself. When nothing installed claims a text
  /// file the menu would be empty, so that answers false and the sheet — now
  /// working — takes over.
  Future<void> _shareLog(List<DebugLogEntry> entries) async {
    final anchor = shareAnchorFor(context, key: _shareButtonKey);
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 19);
      final file = File('${dir.path}/cubechat-log-$stamp.txt');
      await file.writeAsString(_asText(entries));
      if (await OpenIn.handOff(file.path, anchor: anchor)) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'cubechat log',
        sharePositionOrigin: anchor,
      );
    } catch (e) {
      if (!mounted) return;
      showGlassToast(context, 'Could not share the log: $e',
          tone: ToastTone.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final entries = DebugLog.instance.entries;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text('Diagnostics',
            style:
                AppTypography.heading(size: 18, color: AppColors.textOnGlass)),
        actions: [
          IconButton(
            key: _shareButtonKey,
            tooltip: 'Share log file',
            icon: Icon(Icons.ios_share_rounded, color: AppColors.textOnGlass),
            onPressed: entries.isEmpty ? null : () => _shareLog(entries),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: Icon(Icons.copy, color: AppColors.textOnGlass),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _asText(entries)));
              if (!context.mounted) return;
              showCopiedToast(context, t.copied);
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: Icon(Icons.delete_outline, color: AppColors.textOnGlass),
            onPressed: () => DebugLog.instance.clear(),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: entries.isEmpty
            ? Center(
                child: Text(
                  'No log entries yet.\nTrigger a connection and come back.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final e = entries[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${e.at.toIso8601String().substring(11, 23)}  ${e.text}',
                      style: AppTypography.mono(
                          size: 11.5, color: AppColors.textOnGlass),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
