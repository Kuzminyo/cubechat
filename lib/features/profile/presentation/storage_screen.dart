import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/storage_usage.dart';

/// What cubechat is using the phone's disk for, and what it costs to get any of
/// it back.
///
/// Modelled on the storage screen every messenger has, with one difference that
/// changes the whole tone of it: there is no cloud here. Telegram can say "all
/// media stays in the cloud, you can download it again" under its clear button.
/// This app cannot, and a screen that looked the same while meaning something
/// else would be the worst kind of familiar. So the piles are ranked by what
/// losing them costs — [StorageRecovery] — every row says so in a line under
/// its name, and only the cache is ticked when the screen opens.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  StorageReport? _report;
  StorageRoots? _roots;

  /// Ticked for clearing. Starts as the one pile that costs nothing.
  final Set<StorageCategory> _selected = {StorageCategory.cache};

  bool _working = false;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    final roots = _roots ?? await StorageRoots.resolve();
    final report = await scanStorage(roots);
    if (!mounted) return;
    setState(() {
      _roots = roots;
      _report = report;
    });
  }

  int get _selectedBytes {
    final report = _report;
    if (report == null) return 0;
    return _selected.fold<int>(0, (sum, c) => sum + report.bytesOf(c));
  }

  /// True when the tick list contains anything that cannot simply be re-made.
  bool get _selectionCosts => _selected
      .any((c) => c.recovery != StorageRecovery.free && c.clearable);

  Future<void> _clear() async {
    final t = AppLocalizations.of(context);
    final roots = _roots;
    if (roots == null || _selectedBytes == 0) return;

    if (_selectionCosts) {
      final ok = await confirmAction(
        context,
        title: t.storageConfirmTitle(formatBytes(_selectedBytes)),
        message: t.storageConfirmBody,
        confirmLabel: t.storageClear(formatBytes(_selectedBytes)),
      );
      if (!ok || !mounted) return;
    }

    setState(() => _working = true);
    final freed = await clearStorage(_selected, roots);
    await _scan();
    if (!mounted) return;
    setState(() => _working = false);
    showGlassToast(
      context,
      t.storageFreed(formatBytes(freed)),
      icon: Icons.cleaning_services_rounded,
      tone: ToastTone.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final report = _report;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.storageTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: SafeArea(
        top: false,
        child: report == null
            ? Center(
                child: Text(
                  t.storageScanning,
                  style: TextStyle(color: AppColors.textOnGlassDim),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
                children: [
                  _Donut(report: report),
                  const SizedBox(height: 18),
                  Text(
                    t.storageHeadline,
                    textAlign: TextAlign.center,
                    style: AppTypography.heading(
                      size: 20,
                      color: AppColors.textOnGlass,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    report.totalBytes == 0
                        ? t.storageEmpty
                        : t.storageSubtitle(formatBytes(report.totalBytes)),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  GlassCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        for (final bucket in report.buckets)
                          if (!bucket.isEmpty)
                            _CategoryRow(
                              bucket: bucket,
                              share: report.shareOf(bucket.category),
                              selected: _selected.contains(bucket.category),
                              onToggle: bucket.category.clearable
                                  ? () => setState(() {
                                        if (!_selected
                                            .remove(bucket.category)) {
                                          _selected.add(bucket.category);
                                        }
                                      })
                                  : null,
                            ),
                        if (report.totalBytes == 0)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              t.storageEmpty,
                              style: TextStyle(
                                color: AppColors.textOnGlassDim,
                                fontSize: 13,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ClearButton(
                    label: _selectedBytes == 0
                        ? t.storageClearNothing
                        : t.storageClear(formatBytes(_selectedBytes)),
                    enabled: _selectedBytes > 0 && !_working,
                    busy: _working,
                    onTap: _clear,
                  ),
                  const SizedBox(height: 10),
                  // The line that replaces Telegram's "it all stays in the
                  // cloud". It is the opposite statement, and it is the single
                  // most important sentence on this screen.
                  Text(
                    t.storageNoCloud,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.lock_rounded,
                        size: 13,
                        color: AppColors.textOnGlassFaint,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          t.storageWhyHistoryLocked,
                          style: TextStyle(
                            color: AppColors.textOnGlassFaint,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// The palette's own colour, rotated for this slice. See
/// [StorageCategory.hue] for why it is derived rather than picked.
Color storageColor(StorageCategory category) {
  final base = HSLColor.fromColor(AppColors.brandPrimary);
  return base
      .withHue((base.hue + category.hue) % 360)
      // Pinned rather than inherited: some palettes are nearly grey, and a
      // chart of eight indistinguishable slices is not a chart.
      .withSaturation(0.62)
      .withLightness(0.58)
      .toColor();
}

/// The ring.
class _Donut extends StatelessWidget {
  const _Donut({required this.report});

  final StorageReport report;

  @override
  Widget build(BuildContext context) {
    final slices = report.visible;
    return SizedBox(
      height: 210,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(210, 210),
            painter: _DonutPainter(
              slices: [
                for (final bucket in slices)
                  (
                    share: report.shareOf(bucket.category),
                    color: storageColor(bucket.category),
                  ),
              ],
              emptyColor: AppColors.glass(0.10),
              gapColor: AppColors.paneBase,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _totalValue(report.totalBytes),
                style: AppTypography.heading(
                  size: 30,
                  color: AppColors.textOnGlass,
                ),
              ),
              Text(
                _totalUnit(report.totalBytes),
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The number and its unit are drawn on two lines, so they are split here
  /// rather than by hunting for the space in a formatted string.
  static String _totalValue(int bytes) => formatBytes(bytes).split(' ').first;

  static String _totalUnit(int bytes) => formatBytes(bytes).split(' ').last;
}

typedef _Slice = ({double share, Color color});

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.slices,
    required this.emptyColor,
    required this.gapColor,
  });

  final List<_Slice> slices;
  final Color emptyColor;

  /// Painted *into* the gaps rather than left transparent: the ring sits on
  /// glass, and a see-through gap shows the aurora through it, which reads as a
  /// hole in the chart rather than as a separator.
  final Color gapColor;

  /// Radians of gap between neighbouring slices.
  static const double _gap = 0.035;
  static const double _thickness = 34;

  final Paint _arc = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = (math.min(size.width, size.height) - _thickness) / 2;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radius,
    );
    _arc.strokeWidth = _thickness;

    if (slices.isEmpty) {
      _arc.color = emptyColor;
      canvas.drawArc(rect, 0, math.pi * 2, false, _arc);
      return;
    }

    // Start at the top, like every donut anybody has read.
    var start = -math.pi / 2;
    for (final slice in slices) {
      final sweep = slice.share * math.pi * 2;
      // A slice narrower than the gap would render as a gap, so the gap is
      // taken out of the slice only when there is a slice left afterwards.
      final drawn = sweep > _gap * 2 ? sweep - _gap : sweep;
      _arc.color = slice.color;
      canvas.drawArc(rect, start, drawn, false, _arc);
      if (drawn < sweep) {
        _arc.color = gapColor;
        canvas.drawArc(rect, start + drawn, sweep - drawn, false, _arc);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.slices.length != slices.length ||
      old.emptyColor != emptyColor ||
      () {
        for (var i = 0; i < slices.length; i++) {
          if (old.slices[i].share != slices[i].share ||
              old.slices[i].color != slices[i].color) {
            return true;
          }
        }
        return false;
      }();
}

/// One line of the legend: tick, colour, name, what clearing it costs, size.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.bucket,
    required this.share,
    required this.selected,
    required this.onToggle,
  });

  final StorageBucket bucket;
  final double share;
  final bool selected;

  /// Null for the one category that cannot be cleared from here.
  final VoidCallback? onToggle;

  static String label(AppLocalizations t, StorageCategory c) => switch (c) {
        StorageCategory.photos => t.storageCatPhotos,
        StorageCategory.voice => t.storageCatVoice,
        StorageCategory.files => t.storageCatFiles,
        StorageCategory.outbox => t.storageCatOutbox,
        StorageCategory.stickers => t.storageCatStickers,
        StorageCategory.saved => t.storageCatSaved,
        StorageCategory.wallpapers => t.storageCatWallpapers,
        StorageCategory.history => t.storageCatHistory,
        StorageCategory.cache => t.storageCatCache,
      };

  static String recovery(AppLocalizations t, StorageRecovery r) => switch (r) {
        StorageRecovery.free => t.storageRecoveryFree,
        StorageRecovery.gone => t.storageRecoveryGone,
        StorageRecovery.askSender => t.storageRecoveryAskSender,
        StorageRecovery.costsThem => t.storageRecoveryCostsThem,
        StorageRecovery.never => t.storageWhyHistoryLocked,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final color = storageColor(bucket.category);
    final locked = onToggle == null;
    final percent = (share * 100);

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            // The tick doubles as the chart's colour key, exactly as it does on
            // the screen this is modelled on: one mark, two jobs, and no
            // separate row of coloured dots to read across.
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: locked
                    ? AppColors.glass(0.10)
                    : selected
                        ? color
                        : color.withValues(alpha: 0.20),
                border: Border.all(
                  color: locked ? AppColors.glass(0.18) : color,
                  width: 1.5,
                ),
              ),
              child: Icon(
                locked
                    ? Icons.lock_rounded
                    : selected
                        ? Icons.check_rounded
                        : bucket.category.icon,
                size: 14,
                color: locked
                    ? AppColors.textOnGlassFaint
                    : selected
                        ? AppColors.paneBase
                        : color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label(t, bucket.category),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        percent < 1 ? '<1%' : '${percent.round()}%',
                        style: TextStyle(
                          color: AppColors.textOnGlassFaint,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${t.storageFilesCount(bucket.files)} · '
                    '${recovery(t, bucket.category.recovery)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatBytes(bucket.bytes),
              style: TextStyle(
                color: color,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({
    required this.label,
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.brandPrimary.withValues(alpha: 0.22)
                : AppColors.glass(0.07),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: enabled
                  ? AppColors.brandPrimary.withValues(alpha: 0.55)
                  : AppColors.glass(0.12),
            ),
          ),
          child: busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.brandPrimary,
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    color: enabled
                        ? AppColors.textOnGlass
                        : AppColors.textOnGlassFaint,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}
