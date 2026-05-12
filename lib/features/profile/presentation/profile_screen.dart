import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/crypto/identity_service.dart';
import '../../../core/locale/locale_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';

const _appVersion = '0.1.0';
// Nickname is still placeholder — nickname management lands in M5.
const _defaultNickname = 'Anonymous';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final locale = ref.watch(localeControllerProvider);
    final fingerprintAsync = ref.watch(identityFingerprintProvider);
    final fingerprint = fingerprintAsync.maybeWhen(
      data: (v) => v,
      orElse: () => '… … … …  … … … …',
    );
    final fingerprintReady = fingerprintAsync.hasValue;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Row(
              children: [
                const CubeLogo(size: 32),
                const SizedBox(width: 12),
                Expanded(child: Text(t.profileTitle, style: AppTypography.display())),
              ],
            ),
          ),

          // Identity
          GlassCard(
            strong: true,
            padding: const EdgeInsets.all(20),
            borderRadius: 22,
            child: Column(
              children: [
                IdentityAvatar(seed: fingerprint, label: _defaultNickname, size: 72),
                const SizedBox(height: 14),
                Text(
                  _defaultNickname,
                  style: AppTypography.heading(size: 20, color: AppColors.textOnGlass),
                ),
                const SizedBox(height: 4),
                Text(
                  t.profileNickname,
                  style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                ),
                const SizedBox(height: 18),
                _FingerprintRow(
                  label: t.profileFingerprint,
                  value: fingerprint,
                  ready: fingerprintReady,
                ),
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
                const CubeLogo(size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Cubechat',
                        style: AppTypography.heading(size: 15, color: AppColors.textOnGlass),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.profileVersion(_appVersion),
                        style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                      ),
                    ],
                  ),
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
  const _FingerprintRow({
    required this.label,
    required this.value,
    this.ready = true,
  });

  final String label;
  final String value;
  final bool ready;

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
                  style: AppTypography.mono(
                    size: 12.5,
                    color: ready ? AppColors.textOnGlass : AppColors.textOnGlassFaint,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                splashRadius: 18,
                icon: Icon(Icons.copy, size: 16, color: AppColors.textOnGlassDim),
                tooltip: t.copy,
                onPressed: ready
                    ? () async {
                        await Clipboard.setData(ClipboardData(text: value));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: Colors.white.withValues(alpha: 0.12),
                            content: Text(t.copied,
                                style: TextStyle(color: AppColors.textOnGlass)),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }
                    : null,
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

class _EmergencyWipeCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            onTap: () => _confirmWipe(context, ref, t),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWipe(BuildContext context, WidgetRef ref, AppLocalizations t) async {
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
            onPressed: () async {
              await ref.read(identityServiceProvider).wipe();
              // Re-fetch identity — provider will mint a fresh keypair.
              ref.invalidate(identityProvider);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
            },
            child: Text(t.profileEmergencyWipeAction, style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}
