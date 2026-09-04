import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/routing/back_gesture.dart';
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
import '../../../core/notifications/push_registration.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/app_build.dart';
import 'package:saver_gallery/saver_gallery.dart';

import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/context_popup.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../peers/presentation/contact_card_screen.dart';
import '../../files/data/file_transfer_controller.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import 'avatar_screen.dart';
import '../data/discovery_settings_controller.dart';
import '../data/app_lock_controller.dart';
import '../data/nav_bar_controller.dart';
import '../data/quiet_hours_controller.dart';
import '../data/ui_scale_controller.dart';
import '../../backup/presentation/phone_transfer_card.dart';
import '../data/privacy_settings_controller.dart';
import '../data/relay_settings_controller.dart';
import '../../../core/util/platform_info.dart';
import '../../../core/widgets/glass_toast.dart';
import 'dart:async';
import '../../peers/data/peer_discovery_controller.dart';
import 'widgets/code_pad.dart';
import '../data/dead_mans_switch_controller.dart';

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

  /// How far the finger has to travel up the picture before it opens.
  ///
  /// The gesture is on the photograph, not on the list. Pulling the *list*
  /// down used to open it, which put the two things a person wants at the top
  /// of this screen — see the picture, read the settings — on the same axis
  /// fighting each other. Swiping up on the face is a gesture about the face:
  /// it starts on the thing it affects, and everywhere else on the screen
  /// scrolls as it always did.
  static const double _dragToOpen = 48;

  /// How far past the top the list has to be pulled to do the same thing.
  /// Higher than the face's, because the bounce at the end of a flick lives
  /// here and must not count as a decision.
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
    // Two ways in, on purpose. The swipe up the face is the one that reads as
    // being about the picture; pulling the list past its top is the one every
    // other messenger has, and it is what a thumb already at the top of a list
    // does without thinking. Neither costs the other anything: the face claims
    // only drags that start on it.
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

  /// How far this drag has travelled, so a flick and a slow pull both need the
  /// same distance rather than the same speed.
  double _dragOnFace = 0;

  void _faceDragStart() => _dragOnFace = 0;

  void _faceDrag(DragUpdateDetails d) {
    _dragOnFace += d.delta.dy;
    if (_open.isAnimating) return;
    // Up opens, down closes — the picture follows the finger's direction, and
    // the accumulator resets so the same drag cannot toggle twice.
    if (_dragOnFace <= -_dragToOpen && _open.value < 1) {
      _dragOnFace = 0;
      _open.forward();
    } else if (_dragOnFace >= _dragToOpen && _open.value > 0) {
      _dragOnFace = 0;
      _open.reverse();
    }
  }

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
              onFaceDragStart: _faceDragStart,
              onFaceDrag: _faceDrag,
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
          // Android only, because the exemption is an Android concept. iOS has
          // no battery-optimisation whitelist to be let out of: what limits a
          // backgrounded app there is the system's own scheduling, which
          // nothing in an app can opt out of. The row was offering a fix for a
          // problem that does not exist, on the platform where the problem it
          // names is genuinely unsolvable — the worst place to put a button
          // that does nothing.
          if (enabled && PlatformInfo.isAndroid) ...[
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
    final settings = ref.watch(discoverySettingsProvider);
    final on = settings.discoverable;
    // Dead while the radio is off, and visibly so.
    //
    // The card above says as much in words — with the mesh off there is
    // nothing to be discoverable *on* — but it only said it in words, so this
    // switch stayed live and looked like it still meant something. It keeps
    // showing the setting rather than lying about it: the choice is still
    // yours, it simply has nothing to act on until the radio is back.
    final usable = settings.meshEnabled;
    return _frame(
      framed,
      child: Opacity(
        opacity: usable ? 1 : 0.45,
        child: IgnorePointer(
          ignoring: !usable,
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
        ),
      ),
    );
  }
}

/// Wipe the phone if nobody opens the app for long enough.
///
/// Its own row rather than a switch, because the only safe way to arm it is to
/// make somebody choose a number and read a sentence while doing it. There is
/// no confirmation when it fires — there cannot be, since the premise is that
/// nobody is there — so every ounce of the safety lives here.
class _DeadMansRow extends ConsumerWidget {
  const _DeadMansRow();

  static String _label(AppLocalizations t, int days) =>
      days == 0 ? t.deadmanOff : t.deadmanDays(days);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final days = ref.watch(deadMansSwitchProvider).days;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final chosen = await showGlassSheet<int>(
              context: context,
              useRootNavigator: true,
              builder: (sheetContext) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 14),
                    Text(
                      t.deadmanTitle,
                      style: AppTypography.heading(size: AppMenu.title),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        t.deadmanHint,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textOnGlassDim,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final option in DeadMansSwitchController.choices)
                      ListTile(
                        title: Text(
                          _label(t, option),
                          style: TextStyle(
                            color: option == 0
                                ? AppColors.textOnGlass
                                : AppColors.danger,
                          ),
                        ),
                        trailing: option == days
                            ? Icon(Icons.check_rounded,
                                color: AppColors.brandPrimary)
                            : null,
                        onTap: () => Navigator.of(sheetContext).pop(option),
                      ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            );
            if (chosen == null) return;
            await ref.read(deadMansSwitchProvider.notifier).setDays(chosen);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.hourglass_disabled_rounded,
                    size: AppMenu.rowIcon,
                    color: days == 0
                        ? AppColors.textOnGlassDim
                        : AppColors.danger),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t.deadmanTitle,
                    style:
                        TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                  ),
                ),
                Text(
                  _label(t, days),
                  style: TextStyle(
                    color: days == 0
                        ? AppColors.textOnGlassDim
                        : AppColors.danger,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: AppColors.textOnGlassFaint),
              ],
            ),
          ),
        ),
        if (days > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              t.deadmanHint,
              style: TextStyle(
                color: AppColors.textOnGlassDim,
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

/// How long the app may be away before the code is asked for again.
///
/// A lock that asks every single time is the one people turn off, and a lock
/// that never asks is decoration. This is the dial between them, and where it
/// sits is the owner's judgement about their own pocket, not something this
/// app can pick for them.
class _GraceRow extends ConsumerWidget {
  const _GraceRow({required this.seconds});

  final int seconds;

  static String _label(AppLocalizations t, int seconds) {
    if (seconds == 0) return t.appLockGraceNow;
    if (seconds < 60) return t.appLockGraceAfter('$seconds s');
    if (seconds < 3600) return t.appLockGraceAfter('${seconds ~/ 60} min');
    return t.appLockGraceAfter('${seconds ~/ 3600} h');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final chosen = await showGlassSheet<int>(
          context: context,
          useRootNavigator: true,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 14),
                Text(
                  t.appLockGraceTitle,
                  style: AppTypography.heading(size: AppMenu.title),
                ),
                const SizedBox(height: 8),
                for (final option in AppLockController.graceChoices)
                  ListTile(
                    title: Text(
                      _label(t, option),
                      style: TextStyle(color: AppColors.textOnGlass),
                    ),
                    trailing: option == seconds
                        ? Icon(Icons.check_rounded,
                            color: AppColors.brandPrimary)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(option),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
        if (chosen == null) return;
        await ref
            .read(appLockControllerProvider.notifier)
            .setGraceSeconds(chosen);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.timer_outlined,
                size: AppMenu.rowIcon, color: AppColors.textOnGlassDim),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t.appLockGraceTitle,
                style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
              ),
            ),
            Text(
              _label(t, seconds),
              style:
                  TextStyle(color: AppColors.textOnGlassDim, fontSize: 12.5),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: AppColors.textOnGlassFaint),
          ],
        ),
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
/// Turn the lock on with a new code, or off with the current one.
///
/// Both directions ask, and for the same reason: a lock somebody else can
/// switch off from the settings screen is a suggestion, not a lock.
Future<void> _toggleAppLock(
  BuildContext context,
  WidgetRef ref,
  bool on,
) async {
  final t = AppLocalizations.of(context);
  final lock = ref.read(appLockControllerProvider.notifier);
  final code = await _askForCode(
    context,
    title: on ? t.appLockSetTitle : t.appLockOffTitle,
    hint: on ? t.appLockSetHint : t.appLockOffHint,
  );
  if (code == null || code.isEmpty || !context.mounted) return;
  final ok = on ? await lock.enable(code) : await lock.disable(code);
  if (!context.mounted) return;
  showGlassToast(
    context,
    ok ? (on ? t.appLockOn : t.appLockOff) : t.appLockWrong,
    icon: ok ? Icons.lock_rounded : null,
    tone: ok ? ToastTone.success : ToastTone.danger,
  );
}

/// Ask for the code on a keypad of the app's own, not on the system keyboard.
///
/// Two reasons, and the first one was a bug people could not get past. The
/// sheet adds the keyboard inset itself (see `showGlassSheet`), and this
/// builder added it a second time — so with the keyboard up, the Save button
/// sat one whole keyboard-height below the visible sheet. The code could be
/// typed and never submitted, which is what "the lock does not work" turned
/// out to be.
///
/// The second is that a PIN is not text. A numeric keypad is what every phone
/// shows for one, it cannot autocorrect, suggest, or offer to remember the
/// code, and it needs no system keyboard at all — so this sheet has a height
/// that does not move and nothing can slide underneath anything.
Future<String?> _askForCode(
  BuildContext context, {
  required String title,
  required String hint,
}) {
  return showGlassSheet<String>(
    context: context,
    // On the root navigator, so the sheet is above the floating tab bar
    // instead of under it.
    //
    // A glass sheet defaults to the shell's navigator, and the tab bar is
    // drawn over that — which is fine for a short sheet and fatal for a tall
    // one: the keypad reaches the bottom of the screen, and the Save button
    // ended up behind the bar. The code could be typed and not confirmed,
    // which is the second time this sheet has hidden that button.
    useRootNavigator: true,
    builder: (sheetContext) => CodePad(title: title, hint: hint),
  );
}

/// The hours in which the phone stays quiet.
///
/// A switch and, once it is on, the two ends of the night. Muting is per chat
/// and answers "not this person"; this answers "not now", which in a mesh app
/// matters more than most — messages arrive whenever somebody wanders into
/// range, and that is as likely to be three in the morning as three in the
/// afternoon.
class _QuietHoursRow extends ConsumerWidget {
  const _QuietHoursRow();

  static String _clock(BuildContext context, int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref, {
    required bool start,
  }) async {
    final q = ref.read(quietHoursControllerProvider);
    final current = start ? q.fromMinutes : q.toMinutes;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    await ref.read(quietHoursControllerProvider.notifier).setWindow(
          from: start ? minutes : q.fromMinutes,
          to: start ? q.toMinutes : minutes,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final q = ref.watch(quietHoursControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingSwitch(
          icon: q.enabled
              ? Icons.nightlight_round
              : Icons.notifications_active_rounded,
          title: t.quietHoursTitle,
          hint: t.quietHoursHint,
          value: q.enabled,
          onChanged: (on) => unawaited(
            ref.read(quietHoursControllerProvider.notifier).setEnabled(on),
          ),
        ),
        // The two ends only when they mean something. A pair of time buttons
        // under an off switch is furniture.
        if (q.enabled) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ClockButton(
                  label: t.quietHoursFrom,
                  value: _clock(context, q.fromMinutes),
                  onTap: () => unawaited(_pick(context, ref, start: true)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ClockButton(
                  label: t.quietHoursTo,
                  value: _clock(context, q.toMinutes),
                  onTap: () => unawaited(_pick(context, ref, start: false)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ClockButton extends StatelessWidget {
  const _ClockButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.glassFill,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.glass(0.14)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: AppMenu.rowSubtitle,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
}

class _PrivacyCard extends ConsumerWidget {
  const _PrivacyCard({this.framed = true});

  /// False inside an [_ExpandableSection], which frames the group.
  final bool framed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final s = ref.watch(privacySettingsProvider);
    final n = ref.read(privacySettingsProvider.notifier);
    final lock = ref.watch(appLockControllerProvider);
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
          // First, and the odd one out: every other switch here decides what
          // other people are told about you. This one decides whether the
          // person holding the phone is you.
          _SettingSwitch(
            icon: lock.enabled ? Icons.lock_rounded : Icons.lock_open_rounded,
            title: t.appLockTitle,
            hint: lock.enabled ? t.appLockOn : t.appLockHint,
            value: lock.enabled,
            onChanged: (on) => unawaited(_toggleAppLock(context, ref, on)),
          ),
          // Only once there is a lock to delay. Offering the delay first would
          // be a setting for a thing that is not on.
          if (lock.enabled) ...[
            const SizedBox(height: 10),
            _GraceRow(seconds: lock.graceSeconds),
          ],
          const SizedBox(height: 10),
          const _DeadMansRow(),
          const SizedBox(height: 14),
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
          const SizedBox(height: 14),
          _SettingSwitch(
            icon: s.allowForwardLink
                ? Icons.shortcut_rounded
                : Icons.person_off_rounded,
            title: t.privacyForwardLinkTitle,
            hint: t.privacyForwardLinkHint,
            value: s.allowForwardLink,
            // Told to everyone we talk to, not stored and forgotten: the
            // person who forwards is whoever we said something to, and their
            // build is the only place this can be honoured.
            onChanged: (value) async {
              await n.setAllowForwardLink(value);
              await ref
                  .read(messagingServiceProvider)
                  .broadcastForwardPrivacy(allowed: value);
            },
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
          const SizedBox(height: 14),
          const _QuietHoursRow(),
          if (PlatformInfo.isMobile) ...[
            const SizedBox(height: 14),
            const _PushWakeRow(),
          ],
        ],
      ),
    );
  }
}

/// "Wake this phone when something arrives."
///
/// Both phones now, and off until it is turned on. A terminated app receives
/// nothing — APNs on iOS, FCM on Android, and either one needs a server to
/// drive it, which is the one piece of this app that is not peer to peer.
///
/// Android was left out while the foreground service was believed to survive a
/// swipe from recents. It does on some builds and not on others, and the phones
/// where it does not are exactly the ones people report as "messages stopped
/// coming" — so the switch is offered there too.
///
/// The switch says what that costs rather than burying it: the server learns
/// that this npub received something and when, which the relay already sees but
/// is now seen twice. That is a decision, so it is asked as one.
class _PushWakeRow extends ConsumerWidget {
  const _PushWakeRow();

  /// Ask, then take them there. A dialog rather than a toast, because this is
  /// the one failure with something to do about it and a toast is gone before
  /// it can be acted on.
  Future<void> _offerSettings(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations t,
  ) async {
    final go = await confirmAction(
      context,
      title: t.pushWakeDeniedTitle,
      message: t.pushWakeDeniedHint,
      confirmLabel: t.blePermissionOpenSettings,
      destructive: false,
    );
    if (!go) return;
    await ref.read(pushRegistrationProvider).openSystemSettings();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final on = ref.watch(pushEnabledProvider);
    return _SettingSwitch(
      icon: on
          ? Icons.notifications_active_rounded
          : Icons.notifications_off_rounded,
      title: t.pushWakeTitle,
      hint: t.pushWakeHint,
      value: on,
      onChanged: (next) async {
        final outcome = await ref.read(pushEnabledProvider.notifier).set(next);
        if (!context.mounted || !next) return;
        switch (outcome.result) {
          case PushEnableResult.ok:
            break;
          case PushEnableResult.denied:
            // The dead end this used to be. iOS records a refusal and never
            // shows the prompt again, so a toast saying "not allowed" left a
            // switch that could not be turned on and did not say where to go.
            // Settings is the only place it comes back from.
            await _offerSettings(context, ref, t);
          case PushEnableResult.unsupported:
          case PushEnableResult.failed:
            // What the system actually said, when it said anything. The
            // generic line sent people hunting through a log for a sentence
            // the app already had in its hand.
            showGlassToast(
              context,
              outcome.detail ?? t.pushWakeRefused,
              tone: ToastTone.danger,
              duration: const Duration(seconds: 6),
            );
        }
      },
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
  // The number itself, now that the size is a slider rather than three named
  // steps. "115%" answers "did I change anything?" better than a word that has
  // to be mapped back onto a size.
  final factor = scale.factor;
  final size = factor == null
      ? t.profileScaleSystem
      : '${(factor * 100).round()}%';
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
    required this.onFaceDragStart,
    required this.onFaceDrag,
  });

  final String nickname;
  final String fingerprint;

  /// 0 = compact, 1 = full-bleed. The *current value*, not the animation:
  /// the delegate has to compare it against the previous build to know it
  /// must relayout, and two reads of the same controller are always equal.
  final double open;

  final VoidCallback onToggle;

  /// A vertical drag that started on the picture. Up opens it, down closes it
  /// — see [_ProfileScreenState._faceDrag].
  final VoidCallback onFaceDragStart;
  final ValueChanged<DragUpdateDetails> onFaceDrag;

  /// Height of the action row, shared by both states so the buttons do not
  /// jump as the header grows.
  static const double actionsHeight = 58;

  /// The circle at rest.
  ///
  /// Grew with the centring. A 64-point disc in the corner beside a line of
  /// text is a bullet point; the same disc alone in the middle of the screen
  /// with the name under it is a photograph, and it has to be big enough to
  /// look like one.
  static const double avatarSize = 92;

  /// Room under the circle for the name and the line beneath it, before the
  /// action row. Measured against the largest interface size, since that is
  /// the one that overflows.
  static const double nameBlockRoom = 62;

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

  /// The circle now sits above the name rather than beside it, so the compact
  /// header is as tall as that stack: inset, disc, the two lines under it, the
  /// actions. The list's top padding is measured off this — see the header
  /// delegate — so it moves with the layout instead of being guessed at.
  static double compactHeightFor(double topInset) =>
      topInset + 12 + avatarSize + 10 + nameBlockRoom + actionsHeight + 12;

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
          onFaceDragStart: onFaceDragStart,
          onFaceDrag: onFaceDrag,
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
    required this.onFaceDragStart,
    required this.onFaceDrag,
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
  final VoidCallback onFaceDragStart;
  final ValueChanged<DragUpdateDetails> onFaceDrag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = AppLocalizations.of(context);
    final photo = ref.watch(avatarProvider);
    final discoverable = ref.watch(discoverySettingsProvider).discoverable;
    return LayoutBuilder(
      builder: (context, constraints) =>
          _build(context, ref, tt, photo, discoverable, constraints.maxWidth),
    );
  }

  /// The header, given the width it is actually being drawn at.
  ///
  /// Taken from the layout rather than from `MediaQuery`, which is the same
  /// number on a phone and is not the same number anywhere else: under the
  /// capture harness the cover is drawn into a 360-point boundary while the
  /// media query still reports 800, and a disc centred on the latter lands
  /// half off the edge of the former. Centring is a fact about the box this
  /// widget was given.
  Widget _build(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations tt,
    Uint8List? photo,
    bool discoverable,
    double width,
  ) {

    // The circle and the cover are the same rectangle at two sizes; lerping it
    // (and the corner radius with it) is what makes one grow into the other.
    // Centred at rest, full-bleed open. It used to sit in the left corner with
    // the name beside it, which is a list row rather than a profile: the photo
    // is the subject of this screen and the middle is where a subject goes.
    final rect = Rect.lerp(
      Rect.fromLTWH(
        (width - _ProfileCover.avatarSize) / 2,
        topInset + 12,
        _ProfileCover.avatarSize,
        _ProfileCover.avatarSize,
      ),
      Rect.fromLTWH(0, 0, width, height),
      t,
    )!;
    final radius = ui.lerpDouble(_ProfileCover.avatarSize / 2, 0, t)!;

    /// How far the name block leans from centred towards the left edge: 0 at
    /// rest, -1 open. The photo takes the whole width when it is open, and
    /// text centred over a photograph reads as a caption rather than a name.
    final nameAlign = ui.lerpDouble(0, -1, t)!;

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
      // Under the circle now, not beside it.
      topInset + 12 + _ProfileCover.avatarSize + 10,
      height - _ProfileCover.actionsHeight - _coverActionsGap - nameBlockHeight,
      t,
    )!;

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fromRect(
            rect: rect,
            // The picture is the subject of this screen, and to a screen
            // reader it was nothing at all: a tappable rectangle with no name.
            // Flutter's own `labeledTapTargetGuideline` reported it against
            // this screen and against no other, which is how it was found.
            //
            // > **Design guideline — Accessibility > Vision**: "Describe your
            // > app's interface and content for screen readers."
            //
            // [Semantics.image] as well as [Semantics.button], because it is
            // both: the label says what the rectangle is, the action says what
            // happens if you activate it. The drag that does the same job more
            // finely is not announced and cannot be — which is the reason the
            // tap has to be.
            child: Semantics(
              label: tt.profileCoverPhoto,
              image: true,
              button: true,
              onTap: onToggle,
              child: RawGestureDetector(
                // The node above carries the label and the tap; this one would
                // publish a second, nameless tappable rectangle on top of it,
                // which is the shape of the original finding.
                excludeFromSemantics: true,
                // The drag lives on the picture rather than on the list: it is
                // a gesture about the picture, and putting it on the scroll
                // axis made "see the photo" and "read the settings" fight each
                // other.
                //
                // Raw, and eager, because the list is also listening for a
                // vertical drag and an ordinary detector loses that arena —
                // the gesture never arrived at all. Claiming it after two
                // points of travel is what takes it off the scrollable, and
                // only over the picture: everywhere else still scrolls.
                gestures: <Type, GestureRecognizerFactory>{
                  EagerVerticalDragRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          EagerVerticalDragRecognizer>(
                    EagerVerticalDragRecognizer.new,
                    (r) => r
                      ..onStart = ((_) => onFaceDragStart())
                      ..onUpdate = onFaceDrag,
                  ),
                  TapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          TapGestureRecognizer>(
                    TapGestureRecognizer.new,
                    (r) => r.onTap = onToggle,
                  ),
                },
                child: Container(
                  // Keyed for the test that checks it is where it should be:
                  // "centred" is a number, and a golden can show it but cannot
                  // check it.
                  key: const ValueKey('profile-cover-face'),
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
                        ? Border.all(color: AppColors.glass(0.2))
                        : null,
                  ),
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
            // At rest the block keeps 56 clear on both sides: the overflow
            // button sits in that corner and a long nickname ran under it, and
            // matching insets are what make a centred block centred on the
            // screen rather than on the space left over beside the button.
            //
            // Open, it goes back to 16 and ranges left, which is where it sat
            // before any of this — the picture fills the width by then and the
            // button is far above the text.
            left: ui.lerpDouble(56, 16, t)!,
            top: nameTop,
            right: ui.lerpDouble(56, 16, t)!,
            child: Align(
              alignment: Alignment(nameAlign, 0),
              child: Column(
              // Each line centred under the disc at rest, ranged left over the
              // photo once it is open. The switch happens at the halfway point
              // of a drag where every part of the header is already moving,
              // which is the one moment it cannot be noticed — there is no
              // lerp between two cross-axis alignments to be had.
              crossAxisAlignment:
                  t < 0.5 ? CrossAxisAlignment.center : CrossAxisAlignment.start,
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
                  // Shrink-wrapped, so the dot and the line it belongs to are
                  // centred *together* under the name. Left to fill the width
                  // the row stayed put while the text inside it moved, which
                  // is what put the status a few points off the axis
                  // everything else on this header sits on.
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: t < 0.5
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
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
          ),

          Positioned(
            top: topInset + 20,
            right: 6,
            child: _CoverMenuButton(
              // The scrim follows the cover: over a photo the icon needs
              // something to sit on, and at rest — where the background is the
              // app's own — a black disc would be a hole in it.
              scrim: t,
              onPick: (anchor) => unawaited(_showProfileMenu(
                context,
                ref,
                anchor,
                fingerprint: fingerprint,
                nickname: nickname,
              )),
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
                    // Straight to the gallery, with a photo or without one.
                    //
                    // It used to open a preview first when there was already a
                    // photo, because that screen was the only place that could
                    // also remove one. So the pill meant "choose a picture" on
                    // a fresh install and "here is a screen, decide what you
                    // wanted" ever after — a question in the way of the answer.
                    // Removing, saving and looking at it live in the three-dot
                    // menu now, which is where anyone coming from another
                    // messenger looks for them anyway.
                    onTap: () => pickProfileAvatar(context, ref),
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

/// The three dots themselves.
///
/// It reports its own rectangle rather than a touch point: [showAnimatedMenu]
/// hangs a menu from a control's right edge and opens it at the finger when
/// there is no control, and it tells the two apart by whether the anchor has a
/// width.
class _CoverMenuButton extends StatelessWidget {
  const _CoverMenuButton({required this.scrim, required this.onPick});

  /// 0 at rest, 1 when the cover is a full-bleed photo.
  final double scrim;
  final void Function(Rect anchor) onPick;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.34 * scrim),
        shape: const CircleBorder(),
        child: IconButton(
          // Three dots and nothing else, so the only name this control has is
          // the one given here — without it a screen reader reached a button
          // and had nothing to call it. The other overflow buttons in the app
          // are already labelled; this one was missed, and Flutter's
          // `labeledTapTargetGuideline` is what noticed.
          //
          // "Photo options" rather than "More": every other menu in the app is
          // "More", and a reader that says the same word on six screens has
          // told you where the button is and not what it does.
          tooltip: AppLocalizations.of(context).profileCoverMenu,
          onPressed: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            onPick(box.localToGlobal(Offset.zero) & box.size);
          },
          icon: Icon(
            Icons.more_vert_rounded,
            color: AppColors.textOnGlass,
            size: AppMenu.buttonIcon,
          ),
        ),
      );
}

/// What the profile's overflow menu can do.
enum _ProfileMenuAction { view, photo, save, colour, copyLink, remove }

/// The three dots on the cover.
///
/// Everything that can be done *to the picture* used to live on a screen you
/// reached by tapping the picture — which meant the one pill people press to
/// put a photo on for the first time and the one they press to take it off
/// were the same pill, and it opened a preview to ask which. The pill goes
/// straight to the gallery now; the rest of it is here, where a menu is what
/// anybody coming from another messenger reaches for.
Future<void> _showProfileMenu(
  BuildContext context,
  WidgetRef ref,
  Rect anchor, {
  required String fingerprint,
  required String nickname,
}) async {
  final t = AppLocalizations.of(context);
  final photo = ref.read(avatarProvider);
  final choice = await showAnimatedMenu<_ProfileMenuAction>(
    context: context,
    anchor: anchor,
    items: [
      if (photo != null)
        AnimatedMenuItem(
          value: _ProfileMenuAction.view,
          icon: Icons.visibility_outlined,
          label: t.avatarView,
        ),
      AnimatedMenuItem(
        value: _ProfileMenuAction.photo,
        icon: Icons.add_a_photo_rounded,
        label: photo == null ? t.avatarSet : t.avatarChange,
      ),
      if (photo != null)
        AnimatedMenuItem(
          value: _ProfileMenuAction.save,
          icon: Icons.download_rounded,
          label: t.chatMediaSaveToGallery,
        ),
      AnimatedMenuItem(
        value: _ProfileMenuAction.colour,
        icon: Icons.palette_outlined,
        label: t.customizeTitle,
      ),
      AnimatedMenuItem(
        value: _ProfileMenuAction.copyLink,
        icon: Icons.link_rounded,
        label: t.contactCopy,
      ),
      if (photo != null)
        AnimatedMenuItem(
          value: _ProfileMenuAction.remove,
          icon: Icons.delete_outline_rounded,
          label: t.avatarRemove,
          tone: AppColors.danger,
        ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case _ProfileMenuAction.view:
      await Navigator.of(context, rootNavigator: true).push<void>(
        mediaRoute<void>(
          (_) => AvatarScreen(
            seed: fingerprint,
            label: nickname,
            heroTag: 'cover-avatar',
          ),
        ),
      );
    case _ProfileMenuAction.photo:
      await pickProfileAvatar(context, ref);
    case _ProfileMenuAction.save:
      await _saveAvatarToGallery(context, photo!);
    case _ProfileMenuAction.colour:
      context.push('/customize');
    case _ProfileMenuAction.copyLink:
      await _copyMyLink(context, ref);
    case _ProfileMenuAction.remove:
      final yes = await confirmAction(
        context,
        title: t.avatarRemove,
        message: t.avatarRemoveConfirm,
        confirmLabel: t.avatarRemove,
      );
      if (!yes) return;
      await ref.read(avatarProvider.notifier).clear();
  }
}

/// The avatar is held as bytes, not as a file, so there is nothing to copy —
/// it is written out under a name that says where it came from.
Future<void> _saveAvatarToGallery(BuildContext context, Uint8List bytes) async {
  final t = AppLocalizations.of(context);
  try {
    final result = await SaverGallery.saveImage(
      bytes,
      fileName: 'cubechat_avatar_${DateTime.now().millisecondsSinceEpoch}.jpg',
      skipIfExists: false,
    );
    if (!context.mounted) return;
    showGlassToast(
      context,
      result.isSuccess ? t.avatarSaved : t.avatarFailed,
      tone: result.isSuccess ? ToastTone.success : ToastTone.danger,
    );
  } catch (_) {
    if (!context.mounted) return;
    showGlassToast(context, t.avatarFailed, tone: ToastTone.danger);
  }
}

Future<void> _copyMyLink(BuildContext context, WidgetRef ref) async {
  final t = AppLocalizations.of(context);
  // The same card the QR pill shows, in text form. Read rather than watched:
  // this runs once, from a menu row, and the card is a future that is already
  // resolved by the time the profile has been on screen long enough to open
  // one.
  final card = await ref.read(myContactCardProvider.future);
  if (!context.mounted) return;
  await Clipboard.setData(ClipboardData(text: card));
  if (!context.mounted) return;
  showCopiedToast(context, t.contactCopied);
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
