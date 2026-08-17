import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/frame_stats.dart';
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
            icon: Icon(Icons.share_rounded, color: AppColors.textOnGlass),
            onPressed: entries.isEmpty ? null : () => _shareLog(entries),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: Icon(Icons.copy_rounded, color: AppColors.textOnGlass),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _asText(entries)));
              if (!context.mounted) return;
              showCopiedToast(context, t.copied);
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: Icon(Icons.delete_outline_rounded, color: AppColors.textOnGlass),
            onPressed: () => DebugLog.instance.clear(),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const _FramePanel(),
            Expanded(
              child: _buildLog(context, t, entries),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLog(
    BuildContext context,
    AppLocalizations t,
    List<DebugLogEntry> entries,
  ) {
    return entries.isEmpty
        ? Center(
            child: Text(
              'No log entries yet.\nTrigger a connection and come back.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
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
          );
  }
}

/// Live frame cost, split by the thread that paid it.
///
/// Put in front of the log rather than behind a switch because it is only
/// useful while something is being scrolled, and a screen you have to go and
/// enable first is a screen nobody reads at the moment it matters.
class _FramePanel extends StatefulWidget {
  const _FramePanel();

  @override
  State<_FramePanel> createState() => _FramePanelState();
}

class _FramePanelState extends State<_FramePanel> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    FrameStats.instance.start();
    // The stats update per frame; redrawing them per frame would make this
    // panel part of what it is measuring.
    _tick = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    // And stop measuring. `start` was called on the way in and nothing ever
    // undid it, so one visit to this screen left a per-frame callback running
    // for the rest of the process — on every screen, forever, in aid of a
    // panel nobody was looking at any more. Cheap per frame and permanent,
    // which is the shape of a cost that only shows up as warmth.
    //
    // Unless a window was deliberately opened to measure somewhere else, which
    // is the entire point of leaving this screen — that one closes on a timer.
    if (!FrameStats.instance.isHolding) FrameStats.instance.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = FrameStats.instance;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.glass(0.06),
        border: Border.all(color: AppColors.glass(0.12)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Frame cost',
                  style: AppTypography.heading(
                      size: 13, color: AppColors.textOnGlass)),
              GestureDetector(
                onTap: () => setState(FrameStats.instance.reset),
                child: Text('reset',
                    style: TextStyle(
                        color: AppColors.brandPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _line('build (CPU / Dart)', s.avgBuildMs, s.p90BuildMs),
          const SizedBox(height: 3),
          _line('raster (GPU)', s.avgRasterMs, s.p90RasterMs),
          const SizedBox(height: 8),
          Text(
            s.verdict,
            style: TextStyle(
                color: AppColors.brandPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            '${s.sampleCount} frames sampled · ${s.jankyFrames} over 16.7 ms '
            'of ${s.totalFrames}',
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 10.5),
          ),
          const SizedBox(height: 10),
          // The one control this panel needed and did not have. Everything
          // above describes the screen you are looking at, and that is this
          // one — so the answer to "why does it warm up while I scroll" was
          // never in here.
          _HoldButton(
            holding: s.isHolding,
            remaining: s.holdRemaining,
            onArm: () => setState(() => s.hold(const Duration(seconds: 45))),
            onRelease: () => setState(s.releaseHold),
          ),
        ],
      ),
    );
  }

  Widget _line(String label, double avg, double p90) => Row(
        children: [
          Expanded(
            child: Text(label,
                style: AppTypography.mono(
                    size: 11.5, color: AppColors.textOnGlass)),
          ),
          Text(
            'avg ${avg.toStringAsFixed(1)}  p90 ${p90.toStringAsFixed(1)} ms',
            style: AppTypography.mono(
              size: 11.5,
              color: p90 > 16.7
                  ? const Color(0xFFFF6B6B)
                  : AppColors.textOnGlass,
            ),
          ),
        ],
      );
}

/// Arms and disarms the measuring window — see [FrameStats.hold].
class _HoldButton extends StatelessWidget {
  const _HoldButton({
    required this.holding,
    required this.remaining,
    required this.onArm,
    required this.onRelease,
  });

  final bool holding;
  final Duration remaining;
  final VoidCallback onArm;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final label = holding
        ? 'measuring everywhere · ${remaining.inSeconds}s left — tap to stop'
        : 'measure another screen for 45 s';
    return GestureDetector(
      onTap: holding ? onRelease : onArm,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: holding
              ? AppColors.brandPrimary.withValues(alpha: 0.18)
              : AppColors.glass(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: holding
                ? AppColors.brandPrimary.withValues(alpha: 0.55)
                : AppColors.glass(0.14),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              holding ? Icons.stop_circle_outlined : Icons.timer_outlined,
              size: 14,
              color: AppColors.brandPrimary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
