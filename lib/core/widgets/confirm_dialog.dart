import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../../l10n/app_localizations.dart';

/// Ask before doing something the user cannot undo.
///
/// Every destructive action in the app funnels through here so they all look
/// and behave the same: the same glass-on-dark dialog, cancel on the left,
/// the action itself on the right in its own colour, and dismissing by tapping
/// outside counting as "no".
///
/// Returns true only on an explicit confirmation — a barrier dismissal or a
/// back gesture returns false, never null, so callers can't accidentally treat
/// "went away" as "yes".
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,

  /// Red for things that destroy data; the brand colour for merely
  /// consequential ones, like clearing a pin everyone can see.
  bool destructive = true,
}) async {
  final t = AppLocalizations.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
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
      content: message == null
          ? null
          : Text(
              message,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child:
              Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            confirmLabel,
            style: TextStyle(
              color: destructive ? AppColors.danger : AppColors.brandPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}
