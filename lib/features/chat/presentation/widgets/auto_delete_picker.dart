import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import '../../data/conversation_settings_controller.dart';

/// Render an auto-delete lifetime as words.
///
/// Picks the largest unit that divides evenly, so the presets read as "1 day"
/// rather than "24 hours" while a hand-typed 90 minutes stays "90 minutes"
/// instead of becoming an unrecognisable "1.5 hours".
String formatAutoDelete(AppLocalizations t, ChatAutoDelete period) {
  final seconds = period.seconds;
  if (seconds <= 0) return t.contactProfileAutoDeleteOff;
  if (seconds % (24 * 60 * 60) == 0) {
    return t.autoDeleteDays(seconds ~/ (24 * 60 * 60));
  }
  if (seconds % (60 * 60) == 0) {
    return t.autoDeleteHours(seconds ~/ (60 * 60));
  }
  if (seconds % 60 == 0) return t.autoDeleteMinutes(seconds ~/ 60);
  return t.autoDeleteSeconds(seconds);
}

/// Ask for a message lifetime: the presets, plus a way to type any of them.
///
/// Returns null when the user backed out — which is *not* the same as picking
/// "off", so callers must not treat it as a change.
Future<ChatAutoDelete?> showAutoDeletePicker(
  BuildContext context,
  ChatAutoDelete current,
) {
  final t = AppLocalizations.of(context);
  return showDialog<ChatAutoDelete>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: AppColors.glass(0.15)),
      ),
      title: Text(
        t.contactProfileAutoDeleteTitle,
        style: TextStyle(color: AppColors.textOnGlass),
      ),
      children: [
        for (final preset in ChatAutoDelete.presets)
          RadioListTile<ChatAutoDelete>(
            value: preset,
            groupValue: current,
            activeColor: AppColors.brandPrimary,
            title: Text(
              formatAutoDelete(t, preset),
              style: TextStyle(color: AppColors.textOnGlass),
            ),
            onChanged: (value) => Navigator.of(dialogContext).pop(value),
          ),
        // A value that is on but not one of the presets is the user's own, and
        // has to keep its place in the list or selecting nothing would look
        // like "off".
        if (current.isOn && !ChatAutoDelete.presets.contains(current))
          RadioListTile<ChatAutoDelete>(
            value: current,
            groupValue: current,
            activeColor: AppColors.brandPrimary,
            title: Text(
              formatAutoDelete(t, current),
              style: TextStyle(color: AppColors.textOnGlass),
            ),
            onChanged: (value) => Navigator.of(dialogContext).pop(value),
          ),
        const Divider(height: 12, color: Color(0x26FFFFFF)),
        SimpleDialogOption(
          onPressed: () async {
            final custom = await _askCustom(dialogContext, t);
            if (custom == null || !dialogContext.mounted) return;
            Navigator.of(dialogContext).pop(custom);
          },
          child: Row(
            children: [
              Icon(Icons.tune_rounded,
                  color: AppColors.brandPrimary, size: 20),
              const SizedBox(width: 12),
              Text(
                t.autoDeleteCustom,
                style: TextStyle(color: AppColors.brandPrimary),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The custom entry: a number and a unit.
///
/// Two fields rather than a duration picker because the useful range spans
/// seconds to months, and no wheel covers that without becoming a puzzle.
Future<ChatAutoDelete?> _askCustom(
  BuildContext context,
  AppLocalizations t,
) {
  final controller = TextEditingController();
  var unitSeconds = 60 * 60; // hours by default — the most likely custom unit

  return showDialog<ChatAutoDelete>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        int? parsed() {
          final n = int.tryParse(controller.text.trim());
          if (n == null || n <= 0) return null;
          final total = n * unitSeconds;
          return total > ChatAutoDelete.maxSeconds ? null : total;
        }

        return AlertDialog(
          backgroundColor: AppColors.bgTop,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: AppColors.glass(0.15)),
          ),
          title: Text(
            t.autoDeleteCustom,
            style: TextStyle(color: AppColors.textOnGlass, fontSize: 17),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: TextStyle(color: AppColors.textOnGlass),
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  hintText: t.autoDeleteCustomHint,
                  hintStyle: TextStyle(color: AppColors.textOnGlassFaint),
                ),
              ),
              const SizedBox(height: 14),
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                      value: 60, label: Text(t.autoDeleteUnitMinutes)),
                  ButtonSegment(
                      value: 60 * 60, label: Text(t.autoDeleteUnitHours)),
                  ButtonSegment(
                      value: 24 * 60 * 60, label: Text(t.autoDeleteUnitDays)),
                ],
                selected: {unitSeconds},
                onSelectionChanged: (s) =>
                    setDialogState(() => unitSeconds = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t.cancel,
                  style: TextStyle(color: AppColors.textOnGlassDim)),
            ),
            TextButton(
              onPressed: parsed() == null
                  ? null
                  : () => Navigator.of(dialogContext)
                      .pop(ChatAutoDelete(parsed()!)),
              child: Text(t.contactProfileAutoDeleteSet),
            ),
          ],
        );
      },
    ),
  );
}
