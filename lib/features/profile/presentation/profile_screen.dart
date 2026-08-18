import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/routing/page_transitions.dart';
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
import '../../../core/util/app_build.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../files/data/file_transfer_controller.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import 'avatar_screen.dart';
import '../data/discovery_settings_controller.dart';
import '../data/nav_bar_controller.dart';
import '../data/ui_scale_controller.dart';
import '../../backup/presentation/phone_transfer_card.dart';
import '../data/privacy_settings_controller.dart';
import '../data/relay_settings_controller.dart';
import '../../../core/widgets/glass_toast.dart';
import 'dart:async';
import '../../peers/data/peer_discovery_controller.dart';

// The version was a `const '0.1.0'` here, written on the first day and never
// touched — so this screen, the one place a tester checks what they are
// running, was the one place that said the wrong thing. It comes from
// [appVersion] now, which the build script checks against pubspec.

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

        const SizedBox(height: 10),

        // Four groups, all closed to start with. Flat, this screen was thirteen
        // identical panes you had to read end to end to find anything; the
        // summary line on each header is what keeps that from becoming four
        // taps instead — coming here to *check* a setting needs none.
        _ExpandableSection(
          icon: Icons.radar_rounded,
          title: t.profileGroupConnection,
          summary: _connectionSummary(ref, t),
          children: const [
            _TransportRow(),
            _BackgroundModeCard(framed: false),
            _RelayFallbackCard(framed: false),
          ],
        ),

        const SizedBox(height: 10),

        _ExpandableSection(
          icon: Icons.shield_rounded,
          title: t.profileGroupPrivacy,
          summary: _privacySummary(ref, t),
          children: const [
            _MeshSwitchCard(framed: false),
            _DiscoverableCard(framed: false),
            _PrivacyCard(framed: false),
          ],
        ),

        const SizedBox(height: 10),

        _ExpandableSection(
          icon: Icons.swap_horiz_rounded,
          title: t.profileGroupData,
          summary: _dataSummary(ref, t),
          children: const [
            _ContactCardRow(framed: false),
            _FileTransfersCard(framed: false),
            PhoneTransferCard(framed: false),
            _BackupCard(framed: false),
          ],
        ),

        const SizedBox(height: 10),

        // Customisation above the app group, not below it. What is behind
        // this row — the colours, the interface size, the nav bar — is what
        // somebody opening this screen is usually looking for; the group under
        // it is language, storage and the version, which are things you go to
        // once. Asked for directly, and the order now matches how often each
        // is wanted.
        //
        // One row, not a group with a single row in it named the same thing.
        // None of what it holds is a preference picked from a list; they are
        // the shape of the app, arranged on a screen with room to do it.
        _CustomizeRow(summary: _customizeSummary(ref, t)),

        const SizedBox(height: 10),

        _ExpandableSection(
          icon: Icons.tune_rounded,
          title: t.profileGroupApp,
          summary: t.profileVersion(appVersion),
          children: [
            _LanguageRow(locale: locale),
            const _StorageRow(),
            // Diagnostics above the signature, not below it. The name-and-
            // version block reads as the end of a screen — everything under it
            // looks like small print — and Diagnostics is a door, not a
            // footer.
            const _DiagnosticsRow(),
            const _AboutRow(),
          ],
        ),

        const SizedBox(height: 14),

        // Deliberately outside the groups and left last. It is the one control
        // here you might need in a hurry, and a panic button behind a
        // disclosure triangle is not one.
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
  const _BackgroundModeCard({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final enabled = ref.watch(backgroundModeProvider);
    final controller = ref.read(backgroundModeProvider.notifier);
    return _frame(
      framed,
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
                child: Icon(Icons.radar_rounded,
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
                icon: Icon(Icons.battery_saver_rounded,
                    size: 16, color: AppColors.brandPrimary),
                label: Text(
                  t.profileBatteryExempt,
                  style:
                      TextStyle(color: AppColors.brandPrimary, fontSize: 12.5),
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
  const _RelayFallbackCard({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final settings = ref.watch(relaySettingsProvider);
    final on = settings.isActive;

    return _frame(
      framed,
      onTap: () => context.push('/relays'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.glass(0.08),
              border: Border.all(color: AppColors.glass(0.18)),
            ),
            child: Icon(
              on ? Icons.public_rounded : Icons.public_off_rounded,
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
          Icon(Icons.chevron_right_rounded, color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}

class _FileTransfersCard extends ConsumerWidget {
  const _FileTransfersCard({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final tasks = ref.watch(fileTransferControllerProvider).values;
    final active = tasks.where((task) => task.active).length;
    return _frame(
      framed,
      onTap: () => context.push('/transfers'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandPrimary.withValues(alpha: 0.18),
              border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(
              Icons.swap_vert_circle_rounded,
              color: AppColors.brandPrimary,
              size: 19,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.profileFileTransfers,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  active == 0
                      ? t.profileFileTransfersSubtitle
                      : '$active · ${t.profileFileTransfersSubtitle}',
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _frame(
      framed,
      onTap: () => context.push('/backup'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandPrimary.withValues(alpha: 0.18),
              border: Border.all(
                color: AppColors.brandPrimary.withValues(alpha: 0.4),
              ),
            ),
            child: Icon(
              Icons.lock_outline_rounded,
              color: AppColors.brandPrimary,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.profileBackup,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.profileBackupSubtitle,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}

/// Whether the mesh announcement goes out in the clear to everyone in range,
/// or sealed to contacts we already have.
/// The Bluetooth radio itself, on or off.
///
/// Above discoverability on purpose, because it is the larger switch: with the
/// mesh off there is nothing to be discoverable *on*. The pair reads as "may
/// the app use Bluetooth" and then "and if so, may strangers see me".
class _MeshSwitchCard extends ConsumerWidget {
  const _MeshSwitchCard({this.framed = true});

  final bool framed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final on = ref.watch(discoverySettingsProvider).meshEnabled;
    return _frame(
      framed,
      child: _SettingSwitch(
        icon: on ? Icons.bluetooth_rounded : Icons.bluetooth_disabled_rounded,
        title: t.profileMeshSwitch,
        hint: t.profileMeshSwitchHint,
        value: on,
        onChanged: (v) async {
          await ref.read(discoverySettingsProvider.notifier).setMeshEnabled(v);
          // Act on it now rather than at the next lifecycle change: a switch
          // whose effect arrives whenever the app next happens to be resumed
          // is a switch nobody trusts.
          final discovery = ref.read(peerDiscoveryControllerProvider.notifier);
          unawaited(v ? discovery.start() : discovery.suspend());
        },
      ),
    );
  }
}

class _DiscoverableCard extends ConsumerWidget {
  const _DiscoverableCard({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final on = ref.watch(discoverySettingsProvider).discoverable;
    return _frame(
      framed,
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
                  color: AppColors.glass(0.08),
                  border: Border.all(color: AppColors.glass(0.18)),
                ),
                child: Icon(
                  on
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
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
            color: AppColors.glass(0.08),
            border: Border.all(color: AppColors.glass(0.18)),
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
  const _PrivacyCard({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final s = ref.watch(privacySettingsProvider);
    final n = ref.read(privacySettingsProvider.notifier);
    return _frame(
      framed,
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
            icon: s.shareMapLocation
                ? Icons.location_on_rounded
                : Icons.location_off_rounded,
            title: t.profileMapLocation,
            hint: s.shareMapLocation
                ? t.profileMapLocationOnHint
                : t.profileMapLocationOffHint,
            value: s.shareMapLocation,
            onChanged: n.setShareMapLocation,
          ),
          const SizedBox(height: 14),
          _SettingSwitch(
            icon: s.shareLastSeen
                ? Icons.schedule_rounded
                : Icons.history_toggle_off_rounded,
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
                ? Icons.done_all_rounded
                : Icons.remove_done_rounded,
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
  const _ContactCardRow({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _frame(
      framed,
      onTap: () => context.push('/contact'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.glass(0.08),
              border: Border.all(color: AppColors.glass(0.18)),
            ),
            child: Icon(Icons.person_add_alt_rounded,
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
          Icon(Icons.chevron_right_rounded, color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}

/// The one-line state a closed group reports.
///
/// Each reads the same providers the rows inside do, so the header cannot drift
/// out of step with what opening it would show.
String _connectionSummary(WidgetRef ref, AppLocalizations t) {
  final parts = <String>[
    ref.watch(relaySettingsProvider).isActive
        ? t.profileSummaryMeshInternet
        : t.profileSummaryMeshOnly,
    if (ref.watch(backgroundModeProvider)) t.profileSummaryBackgroundOn,
  ];
  return parts.join(' · ');
}

String _privacySummary(WidgetRef ref, AppLocalizations t) {
  final parts = <String>[
    ref.watch(discoverySettingsProvider).discoverable
        ? t.profileSummaryDiscoverable
        : t.profileSummaryHidden,
    if (!ref.watch(privacySettingsProvider).shareLastSeen)
      t.profileSummaryLastSeenHidden,
    if (!ref.watch(privacySettingsProvider).shareMapLocation)
      t.profileSummaryMapHidden,
  ];
  return parts.join(' · ');
}

String _dataSummary(WidgetRef ref, AppLocalizations t) {
  final active = ref
      .watch(fileTransferControllerProvider)
      .values
      .where((task) => task.active)
      .length;
  // A transfer in progress is the only thing in this group that is *happening*
  // rather than merely available, so it takes the line when there is one.
  return active > 0
      ? t.profileSummaryTransfersActive(active)
      : t.profileSummaryCardBackup;
}

/// Static "how messages travel" row. Was a card of its own; inside the
/// connection group it is the first line of an answer the rest of the group
/// completes.
class _TransportRow extends StatelessWidget {
  const _TransportRow();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _frame(
      false,
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
            child:
                Icon(Icons.bluetooth_rounded, color: AppColors.brandPrimary, size: 18),
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
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.online,
            ),
          ),
        ],
      ),
    );
  }
}

// The palette swatches and the interface-size pills both used to live here,
// either side of the language list. Both have moved to the Customization
// screen — see [CustomizeScreen]. What is left in this group are the
// preferences you pick from a fixed list; how the app *looks* is arranged
// somewhere with room for it.

class _LanguageRow extends ConsumerWidget {
  const _LanguageRow({required this.locale});

  final Locale locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return _frame(
      false,
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
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return _frame(
      false,
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
                  t.profileVersion(appVersion),
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Interface size · 5 tabs" — enough to answer "did I change anything?"
/// without opening the screen, which is what every summary here is for.
String _customizeSummary(WidgetRef ref, AppLocalizations t) {
  final scale = ref.watch(uiScaleControllerProvider);
  final layout = ref.watch(navBarControllerProvider);
  final size = switch (scale) {
    UiScale.system => t.profileScaleSystem,
    UiScale.small => t.profileScaleSmall,
    UiScale.normal => t.profileScaleNormal,
    UiScale.large => t.profileScaleLarge,
  };
  return '$size · ${layout.shown.length}/${NavDestination.values.length}';
}

/// A row that opens a screen — the shape a setting takes once it has outgrown
/// a switch.
///
/// [framed] is the same distinction every card here draws: inside a group the
/// group supplies the pane, and standing on its own it needs one of its own.
/// [summary] is what a group header would have said, so a top-level row can
/// still answer "did I change anything?" without being opened.
class _PushRow extends StatelessWidget {
  const _PushRow({
    required this.icon,
    required this.label,
    required this.route,
    this.summary,
    this.framed = false,
  });

  final IconData icon;
  final String label;
  final String route;
  final String? summary;
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final accent = framed ? AppColors.brandPrimary : AppColors.textOnGlass;
    return _frame(
      framed,
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
      onTap: () => context.push(route),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: framed
                  ? AppColors.brandPrimary.withValues(alpha: 0.16)
                  : AppColors.glass(0.08),
              border: Border.all(
                color: framed
                    ? AppColors.brandPrimary.withValues(alpha: 0.36)
                    : AppColors.glass(0.18),
              ),
            ),
            child: Icon(icon, color: accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: framed ? 15 : 14,
                    fontWeight: framed ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (summary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow();

  @override
  Widget build(BuildContext context) => _PushRow(
        icon: Icons.pie_chart_rounded,
        label: AppLocalizations.of(context).storageTitle,
        route: '/storage',
      );
}

class _CustomizeRow extends StatelessWidget {
  const _CustomizeRow({this.summary});

  final String? summary;

  @override
  Widget build(BuildContext context) => _PushRow(
        icon: Icons.dashboard_customize_rounded,
        label: AppLocalizations.of(context).customizeTitle,
        route: '/customize',
        summary: summary,
        framed: true,
      );
}

class _DiagnosticsRow extends StatelessWidget {
  const _DiagnosticsRow();

  @override
  Widget build(BuildContext context) {
    return _frame(
      false,
      onTap: () => context.push('/diagnostics'),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.glass(0.08),
              border: Border.all(color: AppColors.glass(0.18)),
            ),
            child: Icon(Icons.bug_report_rounded,
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
          Icon(Icons.chevron_right_rounded, color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}

/// A settings row's own frame — or, inside an [_ExpandableSection], nothing,
/// because the section already supplies one.
///
/// Every card here was its own pane of glass, which is how the screen ended up
/// as thirteen identical slabs with no shape to it. Grouped, the outer pane is
/// the group and a second border inside it would only redraw the clutter one
/// level down. The parameters deliberately mirror [GlassCard]'s, so a card
/// swaps between the two by changing the constructor name and nothing else.
Widget _frame(
  bool framed, {
  VoidCallback? onTap,
  required Widget child,
  EdgeInsets padding = const EdgeInsets.all(16),
}) {
  if (framed) return GlassCard(padding: padding, onTap: onTap, child: child);
  final bare = Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: child,
  );
  if (onTap == null) return bare;
  // Keeps the ripple a row has when it is its own card. The section wraps its
  // body in a transparent Material so this has something to paint on.
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: bare,
  );
}

/// One collapsible group of settings.
///
/// Collapsed by default and independent of its neighbours: an accordion that
/// closes one thing to open another hides state the user was mid-way through
/// comparing, and there is nothing here expensive enough to justify that.
///
/// [summary] is the point of the header. A group that only says "Connection"
/// makes you open it to learn anything, which is a worse screen than the flat
/// list it replaced; saying "Mesh · internet on" means the common case — coming
/// to check a setting rather than change one — needs no tap at all.
class _ExpandableSection extends StatefulWidget {
  const _ExpandableSection({
    required this.icon,
    required this.title,
    required this.children,
    this.summary,
  });

  final IconData icon;
  final String title;
  final String? summary;
  final List<Widget> children;

  @override
  State<_ExpandableSection> createState() => _ExpandableSectionState();
}

class _ExpandableSectionState extends State<_ExpandableSection>
    with SingleTickerProviderStateMixin {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      borderRadius: 22,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              borderRadius: BorderRadius.circular(22),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.brandPrimary.withValues(alpha: 0.16),
                        border: Border.all(
                          color: AppColors.brandPrimary.withValues(alpha: 0.36),
                        ),
                      ),
                      child: Icon(widget.icon,
                          color: AppColors.brandPrimary, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (widget.summary != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.summary!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textOnGlassDim,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.expand_more_rounded,
                          color: AppColors.textOnGlassFaint),
                    ),
                  ],
                ),
              ),
            ),
            // AnimatedSize over an if: the children keep their state across a
            // collapse, so a switch mid-flight is not rebuilt from scratch when
            // the group is reopened.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 1, color: Color(0x1FFFFFFF)),
                          ...widget.children,
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
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
        color: AppColors.glass(0.06),
        border: Border.all(color: AppColors.glass(0.1)),
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
                    Icon(Icons.copy_rounded, size: 16, color: AppColors.textOnGlassDim),
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
          color: active ? null : AppColors.glass(0.08),
          border: Border.all(
            color: active ? AppColors.glass(0.3) : AppColors.glass(0.15),
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
          side: BorderSide(color: AppColors.glass(0.15)),
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

  /// How tall the cover goes when it is pulled open.
  ///
  /// Back to roughly the old height. Taller sounded like more of the picture
  /// and was the opposite: what is stored is a square, so stretching it down
  /// the screen only scales the same crop up — the photo did not get bigger,
  /// it got closer. Half the screen shows the square nearly whole, and what
  /// decides which part of the photo that square holds is now the crop step
  /// when you choose it.
  static double expandedHeightFor(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.52).clamp(400.0, 470.0);

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
        expanded: expandedHeightFor(context),
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
    required this.expanded,
    required this.topInset,
    required this.builder,
  });

  final double open;
  final double expanded;
  final double compact;
  final double topInset;
  final Widget Function(BuildContext, double height, double t) builder;

  double get _max => compact + (expanded - compact) * open;

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
      old.open != open ||
      old.compact != compact ||
      old.expanded != expanded ||
      old.topInset != topInset;
}

/// The discoverability line under the name, and the room left between that
/// block and the buttons below it.
const double _coverStatusSize = 11.5;
const double _coverActionsGap = 18;

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

    // Measured, not guessed. Open, the name block sits directly above the
    // action row, and where its *top* goes therefore depends on how tall it is
    // — which depends on the font scale. The old fixed 66-point offset was cut
    // for the stock size, so a phone set to larger text (an iPhone in
    // particular, where the system default already runs bigger) pushed the name
    // and the line under it straight down onto the buttons.
    final scaler = MediaQuery.textScalerOf(context);
    final titleSize = ui.lerpDouble(19, 26, t)!;
    final nameBlockHeight = scaler.scale(titleSize) * 1.25 +
        3 +
        scaler.scale(_coverStatusSize) * 1.4;
    final nameTop = ui.lerpDouble(
      topInset + 16,
      height - _ProfileCover.actionsHeight - _coverActionsGap - nameBlockHeight,
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
                  border:
                      t < 0.5 ? Border.all(color: AppColors.glass(0.2)) : null,
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
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // The palette's own deep background, not the emerald
                        // one this was written with. It was a `const` literal
                        // of `bgDeep` — right on the green theme and a band of
                        // dark green across the bottom of every other, which is
                        // the strip under the buttons people kept pointing at.
                        colors: [
                          Colors.transparent,
                          AppColors.bgDeep.withValues(alpha: 0.90)
                        ],
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
                    size: titleSize,
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
                          fontSize: _coverStatusSize,
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
                    icon: Icons.add_a_photo_rounded,
                    label: photo == null ? tt.avatarSet : tt.avatarChange,
                    // With no photo there is nothing to look at, so go straight
                    // to the picker. With one, open the screen that can also
                    // remove it — otherwise there is no way to take an avatar
                    // back off, which is where this ended up before.
                    onTap: () => photo == null
                        ? pickProfileAvatar(context, ref)
                        : Navigator.of(context, rootNavigator: true).push<void>(
                            mediaRoute<void>(
                              (_) => AvatarScreen(
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
                    icon: Icons.edit_rounded,
                    label: tt.profileEditName,
                    onTap: () => editNickname(context, ref, tt, nickname),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CoverAction(
                    icon: Icons.qr_code_2_rounded,
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
      color: AppColors.glass(0.14),
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
        side: BorderSide(color: AppColors.glass(0.15)),
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
              style: TextStyle(color: AppColors.brandPrimary)),
        ),
      ],
    ),
  );
}
