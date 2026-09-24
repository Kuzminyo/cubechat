import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/nearby_offer.dart';
import '../../../core/util/media_storage.dart';
import '../../../core/utils/file_mime.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/file_bubble.dart' show formatBytes;
import '../../files/data/file_transfer_controller.dart';
import '../data/airdrop_history_controller.dart';
import '../domain/airdrop_transfer.dart';
import 'airdrop_text.dart';

String? airdropReasonLabel(AppLocalizations t, NearbyDeclineReason? reason) =>
    switch (reason) {
      // noLocalNetwork only ever rides on an acceptance, never a decline.
      null ||
      NearbyDeclineReason.user ||
      NearbyDeclineReason.noLocalNetwork =>
        null,
      NearbyDeclineReason.noSpace => t.airdropReasonNoSpace,
      NearbyDeclineReason.contactsOnly => t.airdropReasonContactsOnly,
      NearbyDeclineReason.busy => t.airdropReasonBusy,
      NearbyDeclineReason.timeout => t.airdropReasonTimeout,
    };

String airdropOutcomeLabel(AppLocalizations t, AirDropHistoryEntry e) {
  final base = switch (e.outcome) {
    AirDropOutcome.received => t.airdropOutcomeReceived,
    AirDropOutcome.sent => t.airdropOutcomeSent,
    AirDropOutcome.declined => t.airdropOutcomeDeclined,
    AirDropOutcome.cancelled => t.airdropOutcomeCancelled,
    AirDropOutcome.failed => t.airdropInterrupted,
    AirDropOutcome.partial => t.airdropOutcomePartial,
  };
  // noWifiRoute is set on the history entry, not on e.reason (a
  // NearbyDeclineReason) — a Wi-Fi-only send that never found a route never
  // reached the decline handshake, so it has no NearbyDeclineReason at all.
  final why = e.wifiOldVersion
      ? t.airdropWifiOldVersion
      : e.noWifiRoute
          ? t.airdropWifiUnreachable
          : airdropReasonLabel(t, e.reason);
  return why == null ? base : '$base · $why';
}

/// The sender's own words for where things are: "waiting", "accepted ·
/// sending", "not received — maybe an old version".
String airdropPhaseLabel(AppLocalizations t, AirDropTransfer x) =>
    switch (x.phase) {
      AirDropPhase.offered || AirDropPhase.waiting => t.airdropWaiting,
      AirDropPhase.unheard => t.airdropUnheard,
      AirDropPhase.transferring => x.direction == AirDropDirection.outgoing
          ? '${t.airdropAccepted} · ${t.airdropSending}'
          : t.airdropReceiving,
      AirDropPhase.interrupted => t.airdropInterrupted,
      // Dead in practice on a live card: a Wi-Fi-only send that fails this
      // way leaves the live list at once (AirDropTransitions.interrupt /
      // .expire), so nobody sees this phase/flag combination on screen. Kept
      // because it is free and keeps the label honest if that ever changes.
      AirDropPhase.failed when x.wifiOldVersion => t.airdropWifiOldVersion,
      AirDropPhase.failed when x.wifiUnreachable => t.airdropWifiUnreachable,
      _ => '',
    };

TextStyle _dim(double size) =>
    TextStyle(color: AppColors.textOnGlassDim, fontSize: size);

class AirDropRequestCard extends StatelessWidget {
  const AirDropRequestCard({
    super.key,
    required this.transfer,
    required this.onAccept,
    required this.onDecline,
    this.onTap,
    this.floating = false,
  });

  final AirDropTransfer transfer;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback? onTap;

  /// Drawn over arbitrary content — the banner over a chat — rather than on
  /// the aurora. A [GlassCard] is 4-22% white and unblurred: rendered over a
  /// conversation, the bubbles behind read straight through the name and the
  /// buttons. Floating, it takes the composer's own pane (a 52-66% smoked fill
  /// plus the blur), which costs a backdrop pass only while a request is
  /// pending — a minute at most.
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final names = transfer.files.take(3).map((f) => f.name).join(', ');
    final more = transfer.files.length > 3 ? ' …' : '';
    final content = _content(t, names, more);
    if (floating) {
      return FloatingGlass(
        onTap: onTap,
        borderRadius: 24,
        padding: const EdgeInsets.all(16),
        child: content,
      );
    }
    return GlassCard(
      onTap: onTap,
      strong: true,
      borderRadius: 24,
      child: content,
    );
  }

  Widget _content(AppLocalizations t, String names, String more) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IdentityAvatar(
                seed: transfer.peerHex,
                label: transfer.peerName,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transfer.peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      airdropRequestBody(t, transfer),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _dim(13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.file_present_rounded,
                color: AppColors.brandPrimary,
                size: 22,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$names$more',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _dim(12),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: PillButton(
                  label: t.airdropDecline,
                  icon: Icons.close_rounded,
                  onTap: onDecline,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PillButton(
                  label: t.airdropAccept,
                  icon: Icons.check_rounded,
                  active: true,
                  onTap: onAccept,
                ),
              ),
            ],
          ),
        ],
      );
}

class AirDropProgressCard extends StatelessWidget {
  const AirDropProgressCard({
    super.key,
    required this.transfer,
    required this.onCancel,
    this.onRetry,
  });

  final AirDropTransfer transfer;
  final VoidCallback onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IdentityAvatar(
                seed: transfer.peerHex,
                label: transfer.peerName,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            transfer.peerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        // Which radio is actually moving the bytes, not the
                        // channel setting — a transfer already in flight kept
                        // whichever lane it started on.
                        if (transfer.phase == AirDropPhase.transferring ||
                            transfer.phase == AirDropPhase.interrupted) ...[
                          const SizedBox(width: 6),
                          Icon(
                            transfer.wifi
                                ? Icons.wifi_rounded
                                : Icons.bluetooth_rounded,
                            size: 14,
                            color: AppColors.textOnGlassDim,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      airdropPhaseLabel(t, transfer),
                      maxLines: 2,
                      style: _dim(12),
                    ),
                  ],
                ),
              ),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: Text(t.airdropRetry)),
              IconButton(
                tooltip: t.cancel,
                onPressed: onCancel,
                icon: const Icon(Icons.close_rounded, size: 20),
                color: AppColors.textOnGlass,
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final f in transfer.files) _FileProgress(file: f),
        ],
      ),
    );
  }
}

/// One file's bar. Reads the transfer queue by the file's id, rebuilt once
/// per whole percent, and eased between steps like the photo send ring.
class _FileProgress extends ConsumerWidget {
  const _FileProgress({required this.file});

  final AirDropFile file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final percent = ref.watch(
      fileTransferControllerProvider.select(
        (tasks) => ((tasks[file.mediaIdHex]?.progress ?? 0) * 100).floor(),
      ),
    );
    final value = file.done ? 1.0 : percent / 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textOnGlass, fontSize: 13),
                ),
              ),
              Text(formatBytes(file.size), style: _dim(11)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: value),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 4,
                backgroundColor: AppColors.glass(0.08),
                valueColor: AlwaysStoppedAnimation(AppColors.brandPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AirDropHistoryRow extends StatelessWidget {
  const AirDropHistoryRow({super.key, required this.entry});

  final AirDropHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final incoming = entry.direction == AirDropDirection.incoming;
    final total = entry.files.fold<int>(0, (sum, f) => sum + f.size);
    AirDropHistoryFile? opener;
    if (incoming) {
      for (final f in entry.files) {
        if (!f.deleted && MediaPaths.existsOrNull(f.path)) {
          opener = f;
          break;
        }
      }
    }
    final file = opener;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: file == null
          ? null
          : () => OpenFilex.open(file.path!, type: fileMimeType(file.name)),
      child: Row(
        children: [
          Icon(
            incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
            color: AppColors.brandPrimary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.peerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${airdropOutcomeLabel(t, entry)} · '
                  '${airdropWhat(t, [for (final f in entry.files) f.mime])} · '
                  '${formatBytes(total)}',
                  style: _dim(12),
                ),
                if (entry.files.any((f) => f.deleted))
                  Text(
                    t.airdropFileDeleted,
                    style: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            _when(entry.at),
            style: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 11),
          ),
        ],
      ),
    );
  }

  static String _when(DateTime at) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}';
    final today =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return today ? time : '${at.day}.${two(at.month)} $time';
  }
}
