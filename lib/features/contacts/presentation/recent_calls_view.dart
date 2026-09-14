import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../l10n/app_localizations.dart';
import '../../call/data/call_controller.dart';
import '../../call/domain/recent_calls.dart';
import '../../call/presentation/call_screen.dart' show callClock;
import '../../chat/data/messages_controller.dart';
import '../../chats/presentation/chats_list_screen.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';

/// Every remembered call, newest first. See [recentCalls].
final recentCallsProvider = Provider<List<RecentCall>>((ref) {
  return recentCalls(ref.watch(messagesControllerProvider));
});

/// The name to put on a call: the conversation's, or the roster's, or the
/// start of the key when neither knows better.
String _nameFor(WidgetRef ref, String peerId) {
  for (final chat in ref.watch(allChatsProvider)) {
    if (chat.id == peerId && chat.peerName.isNotEmpty) return chat.peerName;
  }
  final known = ref.watch(knownPeersControllerProvider)[peerId];
  if (known != null && known.displayName.isNotEmpty) return known.displayName;
  return peerId.length > 8 ? peerId.substring(0, 8) : peerId;
}

/// The calls half of Contacts, as slivers for the screen's own scroll view.
List<Widget> recentCallSlivers({
  required BuildContext context,
  required WidgetRef ref,
  required bool missedOnly,
  required ValueChanged<bool> onMissedOnly,
  required Widget Function(String label, bool selected, VoidCallback onTap)
      chip,
  required Widget Function(String title, String hint) empty,
}) {
  final t = AppLocalizations.of(context);
  final all = ref.watch(recentCallsProvider);
  final calls = missedOnly
      ? recentCalls(ref.read(messagesControllerProvider), missedOnly: true)
      : all;
  return [
    SliverToBoxAdapter(
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            chip(t.callsFilterAll, !missedOnly, () => onMissedOnly(false)),
            chip(t.callsFilterMissed, missedOnly, () => onMissedOnly(true)),
          ],
        ),
      ),
    ),
    const SliverToBoxAdapter(child: SizedBox(height: 8)),
    if (calls.isEmpty)
      SliverFillRemaining(
        hasScrollBody: false,
        child: empty(
          all.isEmpty ? t.callsEmptyTitle : t.callsMissedEmpty,
          t.callsEmptyHint,
        ),
      )
    else
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
        sliver: SliverList.separated(
          itemCount: calls.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) => _CallRow(call: calls[index]),
        ),
      ),
  ];
}

class _CallRow extends ConsumerWidget {
  const _CallRow({required this.call});

  final RecentCall call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final name = _nameFor(ref, call.peerId);
    final (icon, label) = switch (call.kind) {
      RecentCallKind.incoming => (Icons.call_received_rounded, t.previewCallIncoming),
      RecentCallKind.outgoing => (Icons.call_made_rounded, t.previewCallOutgoing),
      RecentCallKind.missed => (Icons.call_missed_rounded, t.previewCallMissed),
      RecentCallKind.unanswered => (Icons.call_made_rounded, t.callNoAnswer),
    };
    final tone = call.isMissed ? AppColors.danger : AppColors.textOnGlassDim;
    final detail = call.talkedFor > Duration.zero
        ? '$label · ${callClock(call.talkedFor)}'
        : label;

    return FloatingGlass(
      blur: false,
      borderRadius: 18,
      // The conversation, the way a row in Telegram's calls list leads to the
      // person; the phone at the end is the call back.
      onTap: () => context.push(
        '/chat/${Uri.encodeComponent(call.peerId)}'
        '?name=${Uri.encodeQueryComponent(name)}',
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            PeerAvatar(peerId: call.peerId, label: name, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    call.count > 1 ? '$name (${call.count})' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: call.isMissed
                          ? AppColors.danger
                          : AppColors.textOnGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(icon, size: 15, color: tone),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: tone, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatChatListTime(context, call.at),
              style: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 12),
            ),
            IconButton(
              tooltip: t.callsCallBack,
              icon: Icon(Icons.call_rounded, color: AppColors.brandPrimary),
              onPressed: () =>
                  unawaited(ref.read(callControllerProvider).dial(call.peerId)),
            ),
          ],
        ),
      ),
    );
  }
}
