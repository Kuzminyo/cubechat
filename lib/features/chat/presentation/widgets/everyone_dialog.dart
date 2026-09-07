import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';

/// Ask for an action, with "and for them too" as a tick rather than a
/// second button.
///
/// Deleting and pinning both used to offer two buttons — "for me" and "for
/// everyone" — which reads as two different actions and puts the more
/// dangerous one first. It is one action with a reach: the question is whether
/// this happens on their phone as well, and a tick is the shape of that
/// question. It is also the shape every messenger uses for it, so nobody has
/// to read the buttons to find out which one they meant.
///
/// Returns null when it was dismissed, and otherwise whether the tick was set.
/// The caller decides what the tick means; this only asks.
Future<bool?> askWithEveryoneTick(
  BuildContext context, {
  required String title,
  required String everyoneLabel,
  required String confirmLabel,

  /// Whether the tick starts set. Pinning does — a pin is conversation state
  /// and sharing it is the ordinary case. Deleting does not: taking a message
  /// off somebody else's phone is the larger act of the two.
  bool initiallyChecked = false,

  /// Draws the confirm button in the danger colour.
  bool destructive = false,

  /// Whether the tick is offered at all.
  ///
  /// It is not when the reach does not apply — a selection holding somebody
  /// else's message cannot be deleted from their phone, and a box that
  /// silently covers only part of what is ticked is worse than no box. The
  /// dialog is then a plain confirmation and answers false.
  bool offerEveryone = true,
}) {
  final t = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      var everyone = initiallyChecked;
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppColors.bgTop,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: AppColors.glass(0.15)),
          ),
          title: Text(
            title,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          content: offerEveryone
              ? InkWell(
                  borderRadius: BorderRadius.circular(12),
                  // The whole row, not just the box: a twenty-pixel target for
                  // the only decision on the screen is one people miss.
                  onTap: () => setState(() => everyone = !everyone),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: everyone,
                          onChanged: (v) =>
                              setState(() => everyone = v ?? false),
                          activeColor: AppColors.brandPrimary,
                          checkColor: AppColors.bgDeep,
                          side: BorderSide(
                            color: AppColors.glass(0.35),
                            width: 1.5,
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            everyoneLabel,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : null,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                t.cancel,
                style: TextStyle(color: AppColors.textOnGlassDim),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(everyone),
              child: Text(
                confirmLabel,
                style: TextStyle(
                  color: destructive
                      ? AppColors.danger
                      : AppColors.brandPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
