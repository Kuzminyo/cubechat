import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../core/widgets/section_switch.dart';
import '../../../l10n/app_localizations.dart';
import '../data/airdrop_clock.dart';
import '../data/airdrop_controller.dart';
import '../data/airdrop_history_controller.dart';
import '../data/airdrop_lane_controller.dart';
import '../data/airdrop_receive_controller.dart';
import '../data/airdrop_source.dart';
import '../data/airdrop_staged.dart';
import '../domain/airdrop_transfer.dart';
import '../../peers/data/peer_discovery_controller.dart';
import 'airdrop_cards.dart';
import 'airdrop_send_flow.dart';
import 'bump_glow.dart';

/// The middle page of Nearby: who may send, what is asking, what is moving,
/// and what has been.
class AirDropPage extends ConsumerWidget {
  const AirDropPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final state = ref.watch(airdropControllerProvider);
    final history = ref.watch(airdropHistoryProvider);
    final staged = ref.watch(airdropStagedProvider);
    final bluetoothOff = ref.watch(
      peerDiscoveryControllerProvider.select(
        (discovery) => discovery.status == PeerDiscoveryStatus.adapterOff,
      ),
    );
    final controller = ref.read(airdropControllerProvider.notifier);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final now = DateTime.now();

    final list = AppearOnce(
      builder: (context, animate) => ListView(
        // No display title here, and no leading top padding of its own —
        // the Nearby tab's shared header above the switch already names this
        // page and already pads the switch away from it (nearby_screen.dart).
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
        children: [
          if (bluetoothOff) ...[
            GlassCard(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(
                    Icons.bluetooth_disabled_rounded,
                    color: AppColors.warning,
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t.airdropBluetoothNeededHint,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          AppearAnimation(
            enabled: animate && !reduced,
            child: const _ReceiveSwitch(),
          ),
          const SizedBox(height: 12),
          AppearAnimation(
            enabled: animate && !reduced,
            delay: AppearAnimation.stagger(1),
            child: const _LaneSwitch(),
          ),
          const SizedBox(height: 12),
          AppearAnimation(
            enabled: animate && !reduced,
            delay: AppearAnimation.stagger(2),
            child: FloatingGlass(
              blur: false,
              borderRadius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              onTap: () => unawaited(startAirDropSend(context, ref)),
              child: Row(
                children: [
                  Icon(Icons.upload_rounded, color: AppColors.brandPrimary),
                  const SizedBox(width: 12),
                  Text(
                    t.airdropSendFiles,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          AppearAnimation(
            enabled: animate && !reduced,
            delay: AppearAnimation.stagger(3),
            child: staged.isEmpty
                ? _ChooseFilesRow(
                    onTap: () async {
                      final picked = await pickAirDropFiles(context, ref);
                      if (picked == null ||
                          picked.isEmpty ||
                          !context.mounted) {
                        return;
                      }
                      // The checks the send flow makes, made now: a bump
                      // sends the staging with nothing in between.
                      final ok = vetAirDropFilesOrSay(context, picked);
                      if (ok != null) {
                        ref.read(airdropStagedProvider.notifier).state = ok;
                      }
                    },
                  )
                : _StagedFilesCard(
                    staged: staged,
                    onPickPerson: () async {
                      final sent = await startAirDropSend(
                        context,
                        ref,
                        files: staged,
                      );
                      if (sent) {
                        ref.read(airdropStagedProvider.notifier).state =
                            const [];
                      }
                    },
                    onClear: () {
                      ref.read(airdropStagedProvider.notifier).state = const [];
                    },
                  ),
          ),
          const SizedBox(height: 14),
          // A request drops in from above; once accepted, the same slot turns
          // into the progress card instead of one card leaving and another
          // arriving.
          for (final x in state.transfers)
            Padding(
              key: ValueKey('airdrop-${x.id}'),
              padding: const EdgeInsets.only(bottom: 10),
              child: AppearAnimation(
                enabled: !reduced,
                beginOffset: const Offset(0, -0.25),
                child: AnimatedSwitcher(
                  duration: reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 260),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SizeTransition(
                      sizeFactor: animation,
                      axisAlignment: -1,
                      child: child,
                    ),
                  ),
                  child: x.isIncomingRequest
                      ? AirDropRequestCard(
                          key: const ValueKey('request'),
                          transfer: x,
                          onAccept: () => unawaited(controller.accept(x.id)),
                          onDecline: () => unawaited(controller.decline(x.id)),
                        )
                      : AirDropProgressCard(
                          key: const ValueKey('progress'),
                          transfer: x,
                          onCancel: () => unawaited(controller.cancel(x.id)),
                          onRetry: x.phase == AirDropPhase.interrupted &&
                                  x.direction == AirDropDirection.outgoing
                              ? () => unawaited(controller.retry(x.id))
                              : null,
                        ),
                ),
              ),
            ),
          if (state.transfers.isEmpty && history.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Text(
                t.airdropEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            ),
          if (history.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.airdropHistory.toUpperCase(),
                    style: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 11,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(
                    ref.read(airdropHistoryProvider.notifier).clear(),
                  ),
                  child: Text(t.airdropClearHistory),
                ),
              ],
            ),
          for (var i = 0; i < history.length; i++)
            Padding(
              key: ValueKey('history-${history[i].id}'),
              padding: const EdgeInsets.only(bottom: 8),
              // The page arriving staggers its rows; after that only a line
              // that has just been written slides in — a transfer finishing
              // is the one thing worth the motion.
              child: AppearAnimation(
                enabled: !reduced &&
                    (animate ||
                        now.difference(history[i].at) <
                            const Duration(seconds: 2)),
                delay: animate ? AppearAnimation.stagger(i + 3) : Duration.zero,
                child: AirDropHistoryRow(entry: history[i]),
              ),
            ),
        ],
      ),
    );
    // The bump glow rides on top. Its spot here is an empty box that takes no
    // touches — what it draws goes into the overlay, from the top of the
    // screen (see BumpGlow for why), and only while a phone is close.
    return Stack(
      fit: StackFit.expand,
      children: [
        list,
        const Positioned.fill(child: BumpGlow()),
      ],
    );
  }
}

/// "Receive from: Contacts / Everyone 10 min", with the minutes left counting
/// down while the window is open and on screen — the only ticking thing here,
/// and only then.
class _ReceiveSwitch extends ConsumerStatefulWidget {
  const _ReceiveSwitch();

  @override
  ConsumerState<_ReceiveSwitch> createState() => _ReceiveSwitchState();
}

class _ReceiveSwitchState extends ConsumerState<_ReceiveSwitch> {
  Timer? _second;

  @override
  void dispose() {
    _second?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final receive = ref.watch(airdropReceiveProvider);
    final now = ref.read(airdropClockProvider)();
    final everyone = receive.everyoneAt(now);
    if (everyone && TickerMode.valuesOf(context).enabled) {
      _second ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _second?.cancel();
      _second = null;
    }
    final left =
        everyone ? receive.everyoneUntil!.difference(now) : Duration.zero;
    final seconds = (left.inSeconds % 60).toString().padLeft(2, '0');
    final everyoneLabel = everyone
        ? t.airdropEveryoneLeft('${left.inMinutes}:$seconds')
        : t.airdropReceiveEveryone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.airdropReceiveHint,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SectionSwitch(
          labels: [t.airdropReceiveContacts, everyoneLabel],
          selected: everyone ? 1 : 0,
          onSelect: (i) {
            final c = ref.read(airdropReceiveProvider.notifier);
            unawaited(i == 1 ? c.openToEveryone() : c.contactsOnly());
          },
        ),
      ],
    );
  }
}

/// "Channel: Auto / Bluetooth / Wi-Fi" — which radio an outgoing send goes
/// out on. The receiver has no say (see [AirDropLaneController]), so this
/// only ever governs sends this phone makes.
class _LaneSwitch extends ConsumerWidget {
  const _LaneSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final lane = ref.watch(airdropLaneProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.airdropLaneTitle,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SectionSwitch(
          labels: [
            t.airdropLaneAuto,
            t.airdropLaneBluetooth,
            t.airdropLaneWifi,
          ],
          selected: lane.index,
          onSelect: (i) => unawaited(
            ref.read(airdropLaneProvider.notifier).set(AirDropLane.values[i]),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t.airdropLaneHint,
          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
        ),
      ],
    );
  }
}

/// "Choose files" — the same row style as "Send files" above it, but this
/// one only stages what was picked; nothing goes out until a bump or a
/// person is chosen.
class _ChooseFilesRow extends StatelessWidget {
  const _ChooseFilesRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return FloatingGlass(
      blur: false,
      borderRadius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: onTap,
      child: Row(
        children: [
          Icon(Icons.touch_app_rounded, color: AppColors.brandPrimary),
          const SizedBox(width: 12),
          Text(
            t.airdropChooseFiles,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// What "Choose files" turns into once something is staged: how many, and
/// the two ways to send them — bring the phones together (BumpController
/// reads this same provider and clears it once its offer goes out) or pick
/// a person by hand.
class _StagedFilesCard extends StatelessWidget {
  const _StagedFilesCard({
    required this.staged,
    required this.onPickPerson,
    required this.onClear,
  });

  final List<AirDropSource> staged;
  final VoidCallback onPickPerson;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.touch_app_rounded, color: AppColors.brandPrimary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.airdropStagedTitle(staged.length),
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  t.airdropStagedHint,
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                ),
                const SizedBox(height: 10),
                PillButton(
                  label: t.airdropStagedPickPerson,
                  icon: Icons.person_rounded,
                  active: true,
                  onTap: onPickPerson,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: t.cancel,
            onPressed: onClear,
            icon: const Icon(Icons.close_rounded, size: 20),
            color: AppColors.textOnGlass,
          ),
        ],
      ),
    );
  }
}
