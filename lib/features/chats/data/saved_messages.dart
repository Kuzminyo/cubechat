import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';

/// The reserved chat id for notes to yourself.
///
/// `@` cannot collide with either of the other two kinds: a peer chat is keyed
/// by 64 hex characters, a channel starts with `#`. Reserved rather than
/// derived from your own pubkey so the notes survive an identity change —
/// losing everything you saved because a key rotated would be a surprising way
/// to lose it.
const String savedChatId = '@saved';

bool isSavedChat(String chatId) => chatId == savedChatId;

/// Notes to yourself, kept on this device.
///
/// Nothing is sent: there is no peer, no session, no relay. A saved message is
/// written straight into the same store every other conversation uses, which is
/// what makes it searchable, pinnable and forwardable like anything else — and
/// what makes it obey the same Emergency Wipe.
///
/// It also means a saved note never leaves the phone, and there is deliberately
/// no sync: this app has no server to sync through, and inventing one for a
/// scratchpad would be the largest possible answer to the smallest question.
class SavedMessagesController {
  SavedMessagesController(this._ref);

  final Ref _ref;
  static const _uuid = Uuid();

  Future<void> saveText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _ref.read(messagesControllerProvider.notifier).append(
          savedChatId,
          Message(
            id: _uuid.v4(),
            chatId: savedChatId,
            text: trimmed,
            sentAt: DateTime.now(),
            // Yours, always: every note here was written by you, and rendering
            // some of them as though someone else spoke would be a lie the
            // bubble colour tells at a glance.
            isMine: true,
            status: MessageStatus.read,
          ),
        );
  }
}

final savedMessagesControllerProvider = Provider<SavedMessagesController>(
  SavedMessagesController.new,
);
