import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/routing/app_shell.dart';
import '../data/airdrop_controller.dart';
import 'airdrop_cards.dart';
import 'airdrop_navigation.dart';

/// Keeps an incoming request reachable without covering a page's title and
/// tabs: it floats just above the bottom navigation, and above the keyboard
/// when one is up.
///
/// The offset is the bar's real top edge ([AppShell.barTop]) rather than a
/// number: the first cut guessed 104, which cleared the capsule by 7 px at the
/// largest text scale the app allows and would have slid under it the first
/// time the bar grew. Pushed routes have no bar, but the same height clears a
/// chat's single-line composer (about 76 px) — a composer grown
/// by several lines of text or a reply bar is overlapped by the card until the
/// request is answered or expires.
class AirDropRequestOverlay extends StatelessWidget {
  const AirDropRequestOverlay({super.key, required this.onOpen});

  final VoidCallback onOpen;

  /// Air between the card and the bar.
  static const double gap = 8;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Positioned(
      left: 12,
      right: 12,
      bottom: keyboard + AppShell.barTop(context) + gap,
      child: AirDropRequestBanner(onOpen: onOpen),
    );
  }
}

/// A request floats above the bottom navigation over a chat, map,
/// a profile — because it expires in a minute and nobody sits on the AirDrop
/// page waiting. Not over that page, which shows the same card itself.
class AirDropRequestBanner extends ConsumerWidget {
  const AirDropRequestBanner({super.key, required this.onOpen});

  /// Tap on the card: open the AirDrop page.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests =
        ref.watch(airdropControllerProvider.select((s) => s.requests));
    final hidden = ref.watch(airdropPageOnScreenProvider);
    final request = hidden || requests.isEmpty ? null : requests.first;
    final controller = ref.read(airdropControllerProvider.notifier);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 280),
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.3),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: request == null
          ? const SizedBox.shrink(key: ValueKey('no-request'))
          : Material(
              key: ValueKey(request.id),
              type: MaterialType.transparency,
              child: AirDropRequestCard(
                transfer: request,
                floating: true,
                onTap: onOpen,
                onAccept: () => unawaited(controller.accept(request.id)),
                onDecline: () => unawaited(controller.decline(request.id)),
              ),
            ),
    );
  }
}
