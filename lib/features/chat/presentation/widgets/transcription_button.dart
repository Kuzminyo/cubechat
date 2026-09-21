import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';

/// Kept separate from playback progress: recognition only animates while pending.
class TranscriptionButton extends StatelessWidget {
  const TranscriptionButton({
    super.key,
    required this.loading,
    required this.onPressed,
  });

  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).chatTranscribeAction;
    return Semantics(
      label: label,
      button: true,
      onTap: loading ? null : onPressed,
      enabled: !loading && onPressed != null,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: SizedBox(
            width: 44,
            height: 44,
            // A disabled button must still absorb taps: otherwise the circle's
            // playback gesture wins while recognition is pending.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: TextButton(
                onPressed: loading ? null : onPressed,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: AppColors.textOnGlass,
                  disabledForegroundColor: AppColors.textOnGlassFaint,
                  backgroundColor: AppColors.glass(0.10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: loading
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.textOnGlassDim,
                        ),
                      )
                    : const Text('→A', style: TextStyle(fontSize: 15)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
