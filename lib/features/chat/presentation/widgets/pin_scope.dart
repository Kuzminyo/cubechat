import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/transport/messaging_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../data/pinned_controller.dart';
import 'everyone_dialog.dart';

/// Pin or unpin one message, asking who it is for.
///
/// **Why it asks.** Pinning was always an act performed on the other person:
/// their carousel changed too, because "the address is at the top" is only
/// useful if it is at the top for whoever needs the address. A note to yourself
/// in somebody else's conversation is a different thing to want, and putting it
/// in front of them is not part of it — so the two are separate choices rather
/// than one choice with a setting.
///
/// A mine-only pin puts nothing on the wire, and neither does removing one, so
/// there is no protocol change here and nothing for an older build to fail to
/// understand.
///
/// **Why it is a function and not a method.** Pinning has two entry points —
/// the selection toolbar and the long-press menu on a single bubble — and they
/// live in different files. The first version of this asked in one of them and
/// not the other, which was reported as "the choice never appeared": whichever
/// path somebody happens to use is the one that has to ask.
///
/// A channel is not asked. There is no "just for me" reading of a pin in a
/// room, and an option that means the same thing as the other one is noise.
Future<void> togglePinWithScope(
  BuildContext context,
  WidgetRef ref, {
  required String chatId,
  required String wireId,
}) async {
  final pins = ref.read(pinnedControllerProvider.notifier);
  final t = AppLocalizations.of(context);

  // Unpinning asks nothing: it undoes whatever the pin was, and a pin
  // remembers which kind it is.
  if (pins.isPinned(chatId, wireId)) {
    if (pins.isMineOnly(chatId, wireId)) {
      await pins.unpin(chatId, wireId: wireId);
    } else {
      await ref
          .read(messagingServiceProvider)
          .sendPin(chatId, wireId, pinned: false);
    }
    return;
  }

  final shared = chatId.startsWith('#')
      ? true
      : await askWithEveryoneTick(
          context,
          title: t.chatPinTitle,
          everyoneLabel: t.chatPinForBoth,
          confirmLabel: t.chatPinAction,
          // Set, because a pin is conversation state and sharing it is the
          // ordinary case — the choice exists for the other one.
          initiallyChecked: true,
        );
  if (shared == null) return;

  if (shared) {
    await ref
        .read(messagingServiceProvider)
        .sendPin(chatId, wireId, pinned: true);
  } else {
    // Nothing on the wire, which is the whole difference.
    await pins.pin(chatId, wireId, mineOnly: true);
  }
}
