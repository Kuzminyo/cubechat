import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/typography.dart';
import '../../../../l10n/app_localizations.dart';

/// The digits, drawn by the app.
///
/// Shared by the sheet that sets a code and the screen that asks for one, so
/// the two cannot drift into different keypads — which is what a pair of
/// hand-tuned copies always does.
class CodePad extends StatefulWidget {
  const CodePad({
    super.key,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.errorText,
    this.enabled = true,
    this.onSubmit,
  });

  final String title;
  final String hint;

  /// The button under the keys. Defaults to the save wording.
  final String? actionLabel;

  /// Shown in place of the dots when something is wrong or a wait is running.
  final String? errorText;

  /// False while the keys must not do anything — a lockout, for instance.
  final bool enabled;

  /// Given the code. When null the pad pops the route with it instead, which
  /// is what the sheet wants and the lock screen does not: that one stays put
  /// and asks again.
  final void Function(String code)? onSubmit;

  /// Below this the lock would be a formality; [AppLockController.enable]
  /// refuses anything shorter anyway, so the button stays off until then.
  static const int minLength = 4;

  /// Long enough for anybody's code, short enough that the dots stay dots
  /// rather than becoming a line of them.
  static const int maxLength = 12;

  @override
  State<CodePad> createState() => CodePadState();
}

class CodePadState extends State<CodePad> {
  String _code = '';

  void _press(String digit) {
    if (!widget.enabled || _code.length >= CodePad.maxLength) return;
    HapticFeedback.selectionClick();
    setState(() => _code += digit);
  }

  void _backspace() {
    if (_code.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _code = _code.substring(0, _code.length - 1));
  }

  void _submit() {
    if (_code.length < CodePad.minLength || !widget.enabled) return;
    HapticFeedback.lightImpact();
    final onSubmit = widget.onSubmit;
    if (onSubmit == null) {
      Navigator.of(context).pop(_code);
      return;
    }
    onSubmit(_code);
    setState(() => _code = '');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ready = _code.length >= CodePad.minLength && widget.enabled;
    final error = widget.errorText;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: AppTypography.heading(size: AppMenu.title),
            ),
            const SizedBox(height: 6),
            Text(
              widget.hint,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12.5),
            ),
            const SizedBox(height: 18),
            // The wait, when there is one, replaces the dots: nothing typed
            // counts while it runs, so drawing an empty row of them would
            // invite typing.
            if (error != null)
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.danger, fontSize: 12.5),
              )
            else
            // One dot per digit entered, and hollow ones up to the minimum so
            // the length that will be accepted is visible before it is reached.
            SizedBox(
              height: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0;
                      i < (_code.length > CodePad.minLength
                          ? _code.length
                          : CodePad.minLength);
                      i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _code.length
                              ? AppColors.brandPrimary
                              : Colors.transparent,
                          border: Border.all(
                            color: i < _code.length
                                ? AppColors.brandPrimary
                                : AppColors.glass(0.30),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(
                children: [
                  for (final digit in row)
                    Expanded(child: _CodeKey(label: digit, onTap: _press)),
                ],
              ),
            Row(
              children: [
                // Balances the row so 0 sits under 8, which is where a thumb
                // expects it on every phone.
                const Expanded(child: SizedBox(height: 58)),
                Expanded(child: _CodeKey(label: '0', onTap: _press)),
                Expanded(
                  child: _CodeKey(
                    icon: Icons.backspace_outlined,
                    onPressed: _backspace,
                    enabled: _code.isNotEmpty,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandPrimary,
                foregroundColor: Colors.black,
                disabledBackgroundColor: AppColors.glass(0.12),
                disabledForegroundColor: AppColors.textOnGlassFaint,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: ready ? _submit : null,
              child: Text(widget.actionLabel ?? t.profileNicknameSave),
            ),
          ],
        ),
      ),
    );
  }
}

/// One key. A digit, or the one that takes a digit back.
class _CodeKey extends StatelessWidget {
  const _CodeKey({
    this.label,
    this.icon,
    this.onTap,
    this.onPressed,
    this.enabled = true,
  });

  final String? label;
  final IconData? icon;
  final void Function(String)? onTap;
  final VoidCallback? onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final digit = label;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: AppColors.glass(0.07),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: !enabled
              ? null
              : digit != null
                  ? () => onTap?.call(digit)
                  : onPressed,
          child: SizedBox(
            height: 58,
            child: Center(
              child: digit != null
                  ? Text(
                      digit,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  : Icon(
                      icon,
                      size: 22,
                      color: enabled
                          ? AppColors.textOnGlass
                          : AppColors.textOnGlassFaint,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}


