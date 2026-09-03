import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'removed_contacts_controller.dart';

/// Take somebody out of Contacts, and leave the conversation where it is.
///
/// This used to be "forget everything": the roster entry, the messages, the
/// name you gave them, their pins and folders, eleven things in all. That was
/// written to fix a real bug — a deleted contact came back on the next screen
/// wearing the alias you had given them — and it fixed it by deleting more,
/// which turned out to be the wrong half of the problem.
///
/// Deleting a contact and deleting a conversation are different intentions, and
/// the app already has a separate action for each. Somebody tidying their
/// Contacts list is not asking to lose what was said, and losing it cannot be
/// undone. So this takes them off that one screen and touches nothing else.
///
/// What deliberately stays, and why each matters:
///
///   * the roster entry — it holds their keys. Without it you cannot write to
///     them, and "removed from Contacts" must not quietly mean "silenced
///     forever". It is also what the chat list builds its row from, so dropping
///     it would take the conversation off the screen with every message still
///     on disk.
///   * the messages, the alias, the pins, the folders — all of them belong to
///     the conversation, and the conversation is staying.
///
/// The tombstone does the work now. [RemovedContactsController] already stopped
/// an announcement or a beacon from re-creating a contact; the Contacts screen
/// reads it too. A message still lifts it — see the `restore` call in
/// `MessagingService` — and that should stay the road back: with the
/// conversation intact there is nothing left to lose by their writing again,
/// and a list you can leave but never rejoin is a trap.
///
/// To stop somebody reaching you at all, block them. That is a different button
/// doing a different thing: their frames are dropped on arrival and the
/// composer is replaced with a notice.
///
/// The confirmation is the caller's: this asks nothing and undoes nothing.
Future<void> removeFromContacts(WidgetRef ref, String pubkeyHex) async {
  await ref
      .read(removedContactsControllerProvider.notifier)
      .remember(pubkeyHex);
}
