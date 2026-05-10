import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/locale/locale_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';

const _appVersion = '0.1.0';
// Placeholder until Noise key generation lands.
const _mockNickname = 'Anonymous';
const _mockFingerprint = '8a3f 19c2 7e5b 4d09 a1f4 2c88 6b3d 0e57';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final locale = ref.watch(localeControllerProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
              t.profileTitle,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                color: AppColors.textPrimary,
              ),
            ),
          ),

          // Identity
          GlassCard(
            strong: true,
            padding: const EdgeInsets.all(20),
            borderRadius: 22,
            child: Column(
              children: [
                const IdentityAvatar(seed: _mockFingerprint, label: _mockNickname, size: 72),
                const SizedBox(height: 14),
                Text(
                  _mockNickname,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  t.profileNickname,
                  style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                ),
                const SizedBox(height: 18),
                _FingerprintRow(label: t.profileFingerprint, value: _mockFingerprint),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Language toggle
          _SectionLabel(text: t.profileLanguage),
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: _LangPill(
                    label: t.profileLanguageEn,
                    code: 'en',
                    current: locale.languageCode,
                    onTap: () => ref.read(localeControllerProvider.notifier).set(const Locale('en')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _LangPill(
                    label: t.profileLanguageUk,
                    code: 'uk',
                    current: locale.languageCode,
                    onTap: () => ref.read(localeControllerProvider.notifier).set(const Locale('uk')),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Transport
          _SectionLabel(text: t.profileTransport),
          GlassCard(
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandPrimary.withValues(alpha: 0.18),
                    border: Border.all(color: AppColors.brandPrimary.withValues(alpha: 0.4)),
                  ),
                  child: const Icon(Icons.bluetooth, color: AppColors.brandPrimary, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t.profileTransportMesh,
                    style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                  ),
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.online,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // About
          _SectionLabel(text: t.profileAbout),
          GlassCard(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Cubechat',
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  t.profileVersion(_appVersion),
                  style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Emergency wipe
          _EmergencyWipeCard(),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: AppColors.textOnGlassFaint,
          fontSize: 11,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _FingerprintRow extends StatelessWidget {
  const _FingerprintRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 11),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: AppTypography.mono(size: 12.5, color: AppColors.textOnGlass),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                splashRadius: 18,
                icon: Icon(Icons.copy, size: 16, color: AppColors.textOnGlassDim),
                tooltip: t.copy,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      content: Text(t.copied, style: TextStyle(color: AppColors.textOnGlass)),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LangPill extends StatelessWidget {
  const _LangPill({
    required this.label,
    required this.code,
    required this.current,
    required this.onTap,
  });

  final String label;
  final String code;
  final String current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = code == current;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: active ? AppColors.brandGradient : null,
          color: active ? null : Colors.white.withValues(alpha: 0.08),
          border: Border.all(
            color: active
                ? Colors.white.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.15),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _EmergencyWipeCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.danger.withValues(alpha: 0.18),
              border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
            ),
            child: const Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.profileEmergencyWipe,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.profileEmergencyWipeHint,
                  style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          PillButton(
            label: t.profileEmergencyWipeAction,
            onTap: () => _confirmWipe(context, t),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWipe(BuildContext context, AppLocalizations t) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
        title: Text(
          t.profileEmergencyWipeConfirm,
          style: TextStyle(color: AppColors.textOnGlass, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Text(
          t.profileEmergencyWipeConfirmHint,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.profileEmergencyWipeAction, style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}
