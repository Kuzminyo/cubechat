import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/section_switch.dart';
import '../../../l10n/app_localizations.dart';
import '../data/airdrop_clock.dart';
import '../data/airdrop_controller.dart';
import '../data/airdrop_history_controller.dart';
import '../data/airdrop_lane_controller.dart';
import '../data/airdrop_receive_controller.dart';
import '../domain/airdrop_transfer.dart';
import 'airdrop_cards.dart';
import 'airdrop_send_flow.dart';

/// The middle page of Nearby: who may send, what is asking, what is moving,
/// and what has been.
class AirDropPage extends ConsumerWidget {
  const AirDropPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final state = ref.watch(airdropControllerProvider);
    final history = ref.watch(airdropHistoryProvider);
    final controller = ref.read(airdropControllerProvider.notifier);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final now = DateTime.now();

    return AppearOnce(
      builder: (context, animate) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
        children: [
          Row(
            children: [
              Icon(
                Icons.wifi_tethering_rounded,
                color: AppColors.brandPrimary,
                size: 30,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(t.airdropTab, style: AppTypography.display()),
              ),
            ],
          ),
          const SizedBox(height: 14),
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
                          onDecline: () =>
                              unawaited(controller.decline(x.id)),
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
                delay:
                    animate ? AppearAnimation.stagger(i + 2) : Duration.zero,
                child: AirDropHistoryRow(entry: history[i]),
              ),
            ),
        ],
      ),
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
