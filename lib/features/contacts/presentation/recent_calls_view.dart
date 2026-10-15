import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/util/frame_stats.dart';
import '../../../core/util/platform_capabilities.dart';
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
  Widget Function(Widget child)? animate,
  required ValueChanged<bool> onMissedOnly,
  required Widget Function(String label, bool selected, VoidCallback onTap)
      chip,
  required Widget Function(String title, String hint) empty,
  String query = '',
  Map<Object, (Object, Widget)>? rows,
}) {
  final t = AppLocalizations.of(context);
  final all = ref.watch(recentCallsProvider);
  final needle = query.trim().toLowerCase();
  // The Contacts tab has one search for both halves, in its header; here it
  // narrows the calls to the people whose name matches, as it narrows the
  // contacts beside them.
  final calls = (missedOnly
          ? recentCalls(ref.read(messagesControllerProvider), missedOnly: true)
          : all)
      .where(
        (c) =>
            needle.isEmpty ||
            _nameFor(ref, c.peerId).toLowerCase().contains(needle),
      )
      .toList(growable: false);
  // Named here, once, and handed to each row — see [_CallRow.name].
  final names = {for (final c in calls) c.peerId: _nameFor(ref, c.peerId)};
  final wrap = animate ?? (Widget child) => child;
  return [
    SliverToBoxAdapter(
      child: wrap(
        SizedBox(
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
    ),
    const SliverToBoxAdapter(child: SizedBox(height: 8)),
    if (calls.isEmpty)
      SliverFillRemaining(
        hasScrollBody: false,
        child: wrap(
          empty(
            all.isEmpty
                ? t.callsEmptyTitle
                : needle.isNotEmpty
                    ? t.contactsSearchEmpty
                    : t.callsMissedEmpty,
            t.callsEmptyHint,
          ),
        ),
      )
    else
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
        sliver: SliverList.separated(
          itemCount: calls.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final call = calls[index];
            final name = names[call.peerId] ?? call.peerId;
            // The same row as last time while nothing it shows has changed:
            // Flutter skips a widget that is identical to the one it already
            // has, and every rebuild of Contacts — a section switch, a letter
            // typed, somebody coming online — used to redraw all of them.
            // `rows` is the screen's, so it outlives this function.
            final inputs = (
              call.kind,
              call.at,
              call.count,
              call.talkedFor,
              name,
              animate == null,
            );
            final key = (call.peerId, call.at);
            final cached = rows?[key];
            if (cached != null && cached.$1 == inputs) return cached.$2;
            final row = wrap(_CallRow(call: call, name: name));
            rows?[key] = (inputs, row);
            return row;
          },
        ),
      ),
  ];
}

class _CallRow extends ConsumerWidget {
  const _CallRow({required this.call, required this.name});

  final RecentCall call;

  /// Passed in rather than looked up here, as [_ContactTile] takes its tag.
  ///
  /// Looked up here, every row watched the whole chat list and the whole
  /// roster, so any change to either — opening a chat marks it read —
  /// rebuilt all of them, on a tab nobody was looking at. A Galaxy S24+ log
  /// (2026-10-15) had `callRow x10` in every slow frame of a chat open, beside
  /// builds of 17-39 ms against a 120 Hz budget of 8.3.
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    FrameStats.countBuild('callRow');
    final t = AppLocalizations.of(context);
    final (icon, label) = switch (call.kind) {
      RecentCallKind.incoming => (
          Icons.call_received_rounded,
          t.previewCallIncoming
        ),
      RecentCallKind.outgoing => (
          Icons.call_made_rounded,
          t.previewCallOutgoing
        ),
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
            if (ref.watch(platformCapabilitiesProvider).calls)
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
