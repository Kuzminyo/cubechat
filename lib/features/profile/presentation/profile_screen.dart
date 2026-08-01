import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/ble/background_mode_controller.dart';
import '../../../core/crypto/identity_service.dart';
import '../../../core/identity/avatar_controller.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/identity/wipe_service.dart';
import '../../../core/locale/locale_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import 'avatar_screen.dart';
import '../data/discovery_settings_controller.dart';
import '../data/privacy_settings_controller.dart';
import '../data/relay_settings_controller.dart';
import '../../../core/widgets/glass_toast.dart';

const _appVersion = '0.1.0';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  /// 0 = the header is a circle, 1 = it is a full-bleed photo.
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 260),
  );

  /// How far past the top the finger has to pull before the photo opens. Low
  /// enough to feel like the header answers the gesture, high enough that the
  /// ordinary bounce at the top of a list does not trip it.
  static const double _pullToOpen = 64;

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is! ScrollUpdateNotification) return false;
    if (n.metrics.axis != Axis.vertical) return false;

    // Both edges are read off `pixels`, not off OverscrollNotification: under
    // bouncing physics the list is *allowed* past the top, so pulling down is
    // an ordinary update with a negative offset and no overscroll is ever
    // reported. Watching for one meant the gesture did nothing at all.
    final px = n.metrics.pixels;
    if (px <= -_pullToOpen) {
      if (_open.value < 1 && !_open.isAnimating) _open.forward();
    } else if (px > 24) {
      // Scrolling into the content puts the photo away again; left open it
      // would sit under the settings and eat the screen.
      if (_open.value > 0 && !_open.isAnimating) _open.reverse();
    }
    return false;
  }

  void _toggle() =>
      _open.status == AnimationStatus.completed || _open.value > 0.5
          ? _open.reverse()
          : _open.forward();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final locale = ref.watch(localeControllerProvider);
    final nickname = ref.watch(nicknameControllerProvider);
    final fingerprintAsync = ref.watch(identityFingerprintProvider);
    final fingerprint = fingerprintAsync.maybeWhen(
      data: (v) => v,
      orElse: () => '… … … …  … … … …',
    );
    final fingerprintReady = fingerprintAsync.hasValue;

    // Hoisted out of the builder below and handed to AnimatedBuilder as its
    // `child`: the cover animates every frame it is opening, and without
    // this every settings card was rebuilt on each of those frames. The
    // CustomScrollView config is cheap to remake; its contents are not.
    final settings = SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
      sliver: SliverList.list(children: [
        // Identity. The avatar and the name moved up onto the cover, so what
        // is left here is the fingerprint — the part you actually read out
        // loud to someone standing next to you.
        GlassCard(
          strong: true,
          padding: const EdgeInsets.all(20),
          borderRadius: 22,
          child: _FingerprintRow(
            label: t.profileFingerprint,
            value: fingerprint,
            ready: fingerprintReady,
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
                  onTap: () => ref
                      .read(localeControllerProvider.notifier)
                      .set(const Locale('en')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _LangPill(
                  label: t.profileLanguageUk,
                  code: 'uk',
                  current: locale.languageCode,
                  onTap: () => ref
                      .read(localeControllerProvider.notifier)
                      .set(const Locale('uk')),
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
                  border: Border.all(
                      color: AppColors.brandPrimary.withValues(alpha: 0.4)),
                ),
                child: const Icon(Icons.bluetooth,
                    color: AppColors.brandPrimary, size: 18),
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

        const SizedBox(height: 8),
        const _BackgroundModeCard(),

        const SizedBox(height: 8),
        const _RelayFallbackCard(),

        const SizedBox(height: 8),
        const _DiscoverableCard(),

        const SizedBox(height: 8),
        const _PrivacyCard(),

        const SizedBox(height: 8),
        const _ContactCardRow(),

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
                      style: AppTypography.heading(
                          size: 15, color: AppColors.textOnGlass),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.profileVersion(_appVersion),
                      style: TextStyle(
                          color: AppColors.textOnGlassDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Diagnostics
        GlassCard(
          onTap: () => context.push('/diagnostics'),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.08),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                child: Icon(Icons.bug_report_outlined,
                    color: AppColors.textOnGlass, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Diagnostics',
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.textOnGlassFaint),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Emergency wipe
        _EmergencyWipeCard(),
      ]),
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: AnimatedBuilder(
        animation: _open,
        // Passed through untouched on every frame — this is what keeps the
        // settings out of the animation's rebuild.
        child: settings,
        builder: (context, child) => CustomScrollView(
          // Bouncing on both platforms, not just iOS. Android's default
          // clamping physics never lets `pixels` go below zero, so "pull past
          // the top" has nothing to measure and the cover would only ever open
          // on an iPhone — the gesture needs somewhere to travel.
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            _ProfileCover(
              nickname: nickname,
              fingerprint: fingerprint,
              open: _open.value,
              onToggle: _toggle,
            ),
            child!,
          ],
        ),
      ),
    );
  }
}

class _BackgroundModeCard extends ConsumerWidget {
  const _BackgroundModeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final enabled = ref.watch(backgroundModeProvider);
    final controller = ref.read(backgroundModeProvider.notifier);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.brandPrimary.withValues(alpha: 0.18),
                  border: Border.all(
                      color: AppColors.brandPrimary.withValues(alpha: 0.4)),
                ),
                child: const Icon(Icons.podcasts,
                    color: AppColors.brandPrimary, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.profileBackground,
                      style:
                          TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.profileBackgroundSubtitle,
                      style: TextStyle(
                          color: AppColors.textOnGlassDim, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                activeColor: AppColors.brandPrimary,
                onChanged: (v) => controller.setEnabled(v),
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => controller.requestBatteryExemption(),
                icon: const Icon(Icons.battery_saver,
                    size: 16, color: AppColors.brandPrimary),
                label: Text(
                  t.profileBatteryExempt,
                  style: const TextStyle(
                      color: AppColors.brandPrimary, fontSize: 12.5),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Entry point to the Nostr internet fallback (M6). Shows at a glance whether
/// the mesh is currently the only transport, or whether relays are backing it.
class _RelayFallbackCard extends ConsumerWidget {
  const _RelayFallbackCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final settings = ref.watch(relaySettingsProvider);
    final on = settings.isActive;

    return GlassCard(
      onTap: () => context.push('/relays'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.08),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Icon(
              on ? Icons.public : Icons.public_off,
              color: on ? AppColors.brandPrimary : AppColors.textOnGlass,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.relaysTitle,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  on ? t.relaysCardSubtitle : t.relaysStateIdle,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}

/// Whether the mesh announcement goes out in the clear to everyone in range,
/// or sealed to contacts we already have.
class _DiscoverableCard extends ConsumerWidget {
  const _DiscoverableCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final on = ref.watch(discoverySettingsProvider).discoverable;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.08),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                child: Icon(
                  on
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: on ? AppColors.textOnGlass : AppColors.brandPrimary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.profileDiscoverable,
                      style:
                          TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      on
                          ? t.profileDiscoverableOnHint
                          : t.profileDiscoverableOffHint,
                      style: TextStyle(
                          color: AppColors.textOnGlassDim, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Switch(
                value: on,
                activeThumbColor: AppColors.brandPrimary,
                onChanged: (v) => ref
                    .read(discoverySettingsProvider.notifier)
                    .setDiscoverable(v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            t.profileDiscoverableExplainer,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// One labelled switch inside a settings card. Three of these were about to be
/// copy-pasted, and hand-tuned duplicates drift apart the first time any of
/// them is touched.
class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.icon,
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Icon(
            icon,
            color: value ? AppColors.textOnGlass : AppColors.brandPrimary,
            size: 18,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                style:
                    TextStyle(color: AppColors.textOnGlassDim, fontSize: 11.5),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: AppColors.brandPrimary,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Last seen and read receipts — the two things the app says about *you*
/// rather than about your messages. Both symmetric; see [PrivacySettings].
class _PrivacyCard extends ConsumerWidget {
  const _PrivacyCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final s = ref.watch(privacySettingsProvider);
    final n = ref.read(privacySettingsProvider.notifier);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.profilePrivacy,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          _SettingSwitch(
            icon: s.shareLastSeen
                ? Icons.schedule_outlined
                : Icons.history_toggle_off_outlined,
            title: t.profileLastSeen,
            hint: s.shareLastSeen
                ? t.profileLastSeenOnHint
                : t.profileLastSeenOffHint,
            value: s.shareLastSeen,
            onChanged: n.setShareLastSeen,
          ),
          const SizedBox(height: 14),
          _SettingSwitch(
            icon: s.shareReadReceipts
                ? Icons.done_all_outlined
                : Icons.remove_done_outlined,
            title: t.profileReadReceipts,
            hint: s.shareReadReceipts
                ? t.profileReadReceiptsOnHint
                : t.profileReadReceiptsOffHint,
            value: s.shareReadReceipts,
            onChanged: n.setShareReadReceipts,
          ),
          const SizedBox(height: 10),
          Text(
            t.profilePrivacyExplainer,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Way in to the off-mesh introduction flow — share your own identity bundle,
/// or import someone else's, for a chat that starts without Bluetooth ever
/// being involved.
class _ContactCardRow extends StatelessWidget {
  const _ContactCardRow();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      onTap: () => context.push('/contact'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.08),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Icon(Icons.person_add_alt,
                color: AppColors.textOnGlass, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.profileContactCard,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.profileContactCardSubtitle,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: AppColors.textOnGlassFaint),
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
                    color: ready
                        ? AppColors.textOnGlass
                        : AppColors.textOnGlassFaint,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                splashRadius: 18,
                icon:
                    Icon(Icons.copy, size: 16, color: AppColors.textOnGlassDim),
                tooltip: t.copy,
                onPressed: ready
                    ? () async {
                        await Clipboard.setData(ClipboardData(text: value));
                        if (!context.mounted) return;
                        showCopiedToast(context, t.copied);
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
              border:
                  Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
            ),
            child: const Icon(Icons.warning_amber_rounded,
                color: AppColors.danger, size: 18),
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
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
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

  Future<void> _confirmWipe(
      BuildContext context, WidgetRef ref, AppLocalizations t) async {
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
          style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 16,
              fontWeight: FontWeight.w600),
        ),
        content: Text(
          t.profileEmergencyWipeConfirmHint,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.cancel,
                style: TextStyle(color: AppColors.textOnGlassDim)),
          ),
          TextButton(
            onPressed: () async {
              await emergencyWipe(ref);
              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
            },
            child: Text(t.profileEmergencyWipeAction,
                style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}

/// The profile header: a circle at rest, a full-bleed photo when pulled open.
///
/// The first cut made the photo the resting state and spent 380 px of every
/// visit on it. That is the wrong default — you open this screen to change a
/// setting far more often than to look at your own face. So the header sits
/// compact (circle, name, three actions) and only opens when asked: pull down
/// past the top, or tap the circle.
///
/// The two states are one layout driven by a single 0..1 value rather than two
/// widgets swapped over. The circle *becomes* the cover — same rectangle, same
/// corner radius, both interpolated — which is what makes it read as one
/// object growing instead of a cut between screens.
class _ProfileCover extends ConsumerWidget {
  const _ProfileCover({
    required this.nickname,
    required this.fingerprint,
    required this.open,
    required this.onToggle,
  });

  final String nickname;
  final String fingerprint;

  /// 0 = compact, 1 = full-bleed. The *current value*, not the animation:
  /// the delegate has to compare it against the previous build to know it
  /// must relayout, and two reads of the same controller are always equal.
  final double open;

  final VoidCallback onToggle;

  /// Height of the action row, shared by both states so the buttons do not
  /// jump as the header grows.
  static const double actionsHeight = 58;
  static const double avatarSize = 64;
  static const double expandedHeight = 420;

  static double compactHeightFor(double topInset) =>
      topInset + 12 + avatarSize + 14 + actionsHeight + 12;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topInset = MediaQuery.paddingOf(context).top;
    return SliverPersistentHeader(
      // Not pinned. Pinning meant the header had to survive being squeezed to a
      // toolbar, and at that size the circle, the name and the three actions
      // all landed on top of each other — every one of them positioned against
      // a height that had shrunk out from under it. A profile header has
      // nothing to keep on screen once you are reading the settings, so it
      // scrolls away like the content it sits above.
      pinned: false,
      delegate: _CoverDelegate(
        open: open,
        compact: compactHeightFor(topInset),
        topInset: topInset,
        builder: (context, height, t) => _CoverBody(
          nickname: nickname,
          fingerprint: fingerprint,
          height: height,
          t: t,
          topInset: topInset,
          onToggle: onToggle,
        ),
      ),
    );
  }
}

class _CoverDelegate extends SliverPersistentHeaderDelegate {
  _CoverDelegate({
    required this.open,
    required this.compact,
    required this.topInset,
    required this.builder,
  });

  final double open;
  final double compact;
  final double topInset;
  final Widget Function(BuildContext, double height, double t) builder;

  double get _max => compact + (_ProfileCover.expandedHeight - compact) * open;

  @override
  double get maxExtent => _max;

  /// Equal to [maxExtent] on purpose: the header has one height at a time and
  /// simply scrolls off. Letting it shrink is what produced the pile-up — the
  /// avatar was pinned to the top, the actions to the bottom, and the name to a
  /// point in between, so squeezing the box drove all three together.
  @override
  double get minExtent => _max;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return SizedBox(
      height: _max,
      child: builder(context, _max, open),
    );
  }

  @override
  bool shouldRebuild(_CoverDelegate old) =>
      old.open != open || old.compact != compact || old.topInset != topInset;
}

class _CoverBody extends ConsumerWidget {
  const _CoverBody({
    required this.nickname,
    required this.fingerprint,
    required this.height,
    required this.t,
    required this.topInset,
    required this.onToggle,
  });

  final String nickname;
  final String fingerprint;
  final double height;

  /// 0 = circle in the corner, 1 = photo filling the header.
  final double t;
  final double topInset;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = AppLocalizations.of(context);
    final photo = ref.watch(avatarProvider);
    final discoverable = ref.watch(discoverySettingsProvider).discoverable;
    final width = MediaQuery.sizeOf(context).width;

    // The circle and the cover are the same rectangle at two sizes; lerping it
    // (and the corner radius with it) is what makes one grow into the other.
    final rect = Rect.lerp(
      Rect.fromLTWH(16, topInset + 12, _ProfileCover.avatarSize,
          _ProfileCover.avatarSize),
      Rect.fromLTWH(0, 0, width, height),
      t,
    )!;
    final radius = ui.lerpDouble(_ProfileCover.avatarSize / 2, 0, t)!;

    final nameLeft = ui.lerpDouble(16 + _ProfileCover.avatarSize + 14, 16, t)!;
    final nameTop = ui.lerpDouble(
      topInset + 16,
      height - _ProfileCover.actionsHeight - 66,
      t,
    )!;

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fromRect(
            rect: rect,
            child: GestureDetector(
              onTap: onToggle,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  gradient: photo == null
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: IdentityAvatar.paletteFor(fingerprint),
                        )
                      : null,
                  image: photo == null
                      ? null
                      : DecorationImage(
                          image: MemoryImage(photo), fit: BoxFit.cover),
                  border: t < 0.5
                      ? Border.all(color: Colors.white.withValues(alpha: 0.2))
                      : null,
                ),
              ),
            ),
          ),

          // Only over the photo: at rest the name sits on the app background
          // and needs nothing, but the app has no say in what people pick and a
          // bright picture would swallow it.
          if (t > 0.01)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: height * 0.55,
              child: IgnorePointer(
                child: Opacity(
                  opacity: t,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xE606140D)],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          Positioned(
            left: nameLeft,
            top: nameTop,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.heading(
                    size: ui.lerpDouble(19, 26, t)!,
                    color: AppColors.textOnGlass,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: discoverable
                            ? AppColors.online
                            : AppColors.textOnGlassDim,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        discoverable
                            ? tt.profileDiscoverableOnHint
                            : tt.profileDiscoverableOffHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textOnGlassDim,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            height: _ProfileCover.actionsHeight,
            child: Row(
              children: [
                Expanded(
                  child: _CoverAction(
                    icon: Icons.add_a_photo_outlined,
                    label: photo == null ? tt.avatarSet : tt.avatarChange,
                    // With no photo there is nothing to look at, so go straight
                    // to the picker. With one, open the screen that can also
                    // remove it — otherwise there is no way to take an avatar
                    // back off, which is where this ended up before.
                    onTap: () => photo == null
                        ? pickProfileAvatar(context, ref)
                        : Navigator.of(context, rootNavigator: true).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => AvatarScreen(
                                seed: fingerprint,
                                label: nickname,
                                heroTag: 'cover-avatar',
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CoverAction(
                    icon: Icons.edit_outlined,
                    label: tt.profileEditName,
                    onTap: () => editNickname(context, ref, tt, nickname),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CoverAction(
                    icon: Icons.qr_code_2_outlined,
                    label: tt.profileMyCard,
                    onTap: () => context.push('/contact'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the three pills sitting on the cover photo.
class _CoverAction extends StatelessWidget {
  const _CoverAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // Sized to sit inside [_ProfileCover.actionsHeight] with room to spare;
        // the row gives a fixed height, so anything taller is an overflow
        // rather than a scroll.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: Colors.white),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rename dialog, at top level because two places open it now: the name in
/// the identity card and the button on the cover.
Future<void> editNickname(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations t,
  String current,
) async {
  final controller = TextEditingController(text: current);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      title: Text(
        t.profileNicknameEditTitle,
        style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 16,
            fontWeight: FontWeight.w600),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: NicknameController.maxLength,
        cursorColor: AppColors.brandPrimary,
        style: TextStyle(color: AppColors.textOnGlass, fontSize: 16),
        decoration: InputDecoration(
          hintText: t.profileNicknameHint,
          hintStyle: TextStyle(color: AppColors.textOnGlassFaint),
          counterStyle:
              TextStyle(color: AppColors.textOnGlassDim, fontSize: 11),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.glassBorder),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: AppColors.brandPrimary, width: 1.5),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child:
              Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
        ),
        TextButton(
          onPressed: () async {
            final value = controller.text.trim();
            if (value.isEmpty) {
              Navigator.of(ctx).pop();
              return;
            }
            await ref.read(nicknameControllerProvider.notifier).set(value);
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: Text(t.profileNicknameSave,
              style: const TextStyle(color: AppColors.brandPrimary)),
        ),
      ],
    ),
  );
}
