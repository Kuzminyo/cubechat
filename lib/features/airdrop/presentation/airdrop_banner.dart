import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/airdrop_controller.dart';
import 'airdrop_cards.dart';
import 'airdrop_navigation.dart';

/// A request drops in from the top over whatever is open — a chat, the map,
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
          begin: const Offset(0, -1.2),
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
                onTap: onOpen,
                onAccept: () => unawaited(controller.accept(request.id)),
                onDecline: () => unawaited(controller.decline(request.id)),
              ),
            ),
    );
  }
}
