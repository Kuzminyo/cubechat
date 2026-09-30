import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../l10n/app_localizations.dart';
import '../../profile/data/privacy_settings_controller.dart';

/// "Who can message me from the internet": everyone, by request, nobody.
///
/// One widget in three places — Profile → Privacy, the contact-card screen
/// and Cube ID — because the question belongs wherever somebody is deciding
/// how findable to be. Bluetooth neighbours are never affected; see
/// `strangerVerdict`.
class StrangerReachSelector extends ConsumerWidget {
  const StrangerReachSelector({
    super.key,
    this.showHint = true,
    this.showTitle = true,
  });

  final bool showHint;

  /// False where a section subheader above already asks the question.
  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final reach = ref.watch(
      privacySettingsProvider.select((s) => s.strangerReach),
    );
    // One line per label: "Через запит" wrapped onto two in a third of a
    // phone's width, and the control grew a row taller than its neighbours.
    Widget label(String text) => Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: const TextStyle(fontSize: 13.5),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle) ...[
          Text(
            t.strangerReachTitle,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<StrangerReach>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: StrangerReach.all,
                label: label(t.strangerReachAll),
              ),
              ButtonSegment(
                value: StrangerReach.request,
                label: label(t.strangerReachRequest),
              ),
              ButtonSegment(
                value: StrangerReach.none,
                label: label(t.strangerReachNone),
              ),
            ],
            selected: {reach},
            onSelectionChanged: (v) => unawaited(
              ref
                  .read(privacySettingsProvider.notifier)
                  .setStrangerReach(v.first),
            ),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 6),
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.textOnGlass
                    : AppColors.textOnGlassDim,
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.brandPrimary.withValues(alpha: 0.35)
                    : Colors.transparent,
              ),
            ),
          ),
        ),
        if (showHint) ...[
          const SizedBox(height: 6),
          Text(
            t.strangerReachHint,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }
}
