import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../models/message.dart';

/// Conversations on disk, one record per message.
///
/// **What this replaces.** History used to be one Hive entry per conversation,
/// holding a list of every message in it. Every change wrote that entry whole —
/// so a read receipt landing on a two-year-old chat re-encoded and re-encrypted
/// two years of messages to record one tick, and a reaction cost the same. The
/// price of the cheapest possible edit grew with the length of the
/// conversation, which is backwards: the longer somebody uses the app, the more
/// every small thing costs them.
///
/// A record per message makes that edit a single `put`. What it costs instead
/// is knowing *which* messages changed, and the controller happens to make that
/// free: every mutation there is `[...current]..[idx] = one.copyWith(...)`, so
/// each untouched message is the same object it was before. Comparing by
/// identity finds the changed ones in a walk of pointers — no encoding, no
/// hashing, no comparing of fields.
///
/// **Ordering.** Records carry a sequence number and are sorted by it on load,
/// which reproduces the order the list was built in. That matters because the
/// list is not sorted by time: a relay hands over a backlog whenever it
/// reconnects, so a message written on Tuesday can be appended after one
/// written on Friday, and the conversation reads in the order it arrived. Right
/// or wrong, it is what these chats look like today, and a storage change is
/// not the place to alter it.
///
/// **What this does not fix yet.** Startup still reads every record: the chat
/// list is built from full history — the preview, the unread count and the sort
/// all come from it — so nothing can be left on disk until that changes. This
/// class is the half that makes writing cheap. Reading lazily is the other half
/// and is a separate piece of work.
class MessageStore {
  MessageStore({required this.encode, required this.decode});

  /// The controller's codec. It stays there: it is the schema, several tests
  /// round-trip it directly, and moving it here would buy nothing.
  final Map<String, dynamic> Function(Message) encode;
  final Message Function(Map<String, dynamic>) decode;

  /// Separates the chat from the message in a record key.
  ///
  /// A NUL, because it is the one character that cannot appear in either half.
  /// A message id is `m<microseconds>`; a chat id is hex, the notebook, or a
  /// channel name — and a channel name is whatever somebody typed, so a
  /// separator that could plausibly occur in one is a bug waiting for the first
  /// person to name a channel with it.
  ///
  /// Built rather than written as a literal, so the byte itself never appears
  /// in this file. A source file carrying a NUL is a binary file to grep, to a
  /// diff, and to half the tools that would otherwise be able to read it.
  static final String _sep = String.fromCharCode(0);

  /// Set once the v1 buckets have been copied across. Written into the same
  /// box, so the check costs nothing and cannot drift from what it describes;
  /// keyed so that [_split] rejects it as a record.
  static final String _importedKey = '${_sep}v1-imported';

  /// The sequence number, stored beside the message's own fields. Read back by
  /// this class and ignored by [decode], which only looks at the keys it knows.
  static const String _seqField = '_seq';

  Box<Map<dynamic, dynamic>>? _box;

  /// What was last written for each chat, by reference.
  ///
  /// The whole point of the diff: these are the same [Message] objects that are
  /// in the controller's state, so this map costs a pointer each and lets the
  /// next write skip everything that did not change.
  final Map<String, List<Message>> _written = <String, List<Message>>{};

  /// Next free sequence number per chat. Derived from what was on disk at load,
  /// so it never collides with a record already there.
  final Map<String, int> _nextSeq = <String, int>{};

  bool get isOpen => _box != null;

  /// Open the box, import the old format if this is the first run on it, and
  /// return every conversation.
  ///
  /// [isDurableChatId] decides which chat ids are real; anything else is a
  /// leftover bucket and its records are dropped, exactly as the previous
  /// format's loader did.
  Future<Map<String, List<Message>>> load({
    required bool Function(String) isDurableChatId,
  }) async {
    final box = await hiveCipherProvider
        .openEncryptedBox<Map<dynamic, dynamic>>(HiveBoxes.messageRecords);
    _box = box;
    await _importV1IfNeeded(box);

    final byChat = <String, List<(int, Message)>>{};
    final strays = <dynamic>[];
    for (final key in box.keys) {
      if (key == _importedKey) continue;
      final split = _split(key);
      if (split == null) {
        strays.add(key);
        continue;
      }
      final chatId = split.$1;
      if (!isDurableChatId(chatId)) {
        strays.add(key);
        continue;
      }
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final map = raw.cast<String, dynamic>();
        final seq = map[_seqField] as int? ?? 0;
        (byChat[chatId] ??= <(int, Message)>[]).add((seq, decode(map)));
      } catch (e) {
        debugPrint('skip corrupt message record "$key": $e');
        strays.add(key);
      }
    }

    for (final key in strays) {
      try {
        await box.delete(key);
      } catch (e) {
        debugPrint('could not drop message record "$key": $e');
      }
    }

    final out = <String, List<Message>>{};
    for (final entry in byChat.entries) {
      final rows = entry.value..sort((a, b) => a.$1.compareTo(b.$1));
      out[entry.key] = [for (final row in rows) row.$2];
      _nextSeq[entry.key] = rows.isEmpty ? 0 : rows.last.$1 + 1;
    }
    return out;
  }

  /// Remember what the caller decided the conversation is, without writing.
  ///
  /// Used after the loader has healed a conversation in memory — dropping
  /// duplicates, say — so the next real write does not mistake the healed list
  /// for a change to every message in it.
  void adopt(String chatId, List<Message> messages) {
    _written[chatId] = messages;
  }

  /// Write [messages] as this chat's history, touching only what changed.
  Future<void> write(String chatId, List<Message> messages) async {
    final box = _box;
    if (box == null) return;

    final before = _written[chatId] ?? const <Message>[];
    final previous = <String, Message>{for (final m in before) m.id: m};
    var seq = _nextSeq[chatId] ?? 0;

    final writes = <String, Map<String, dynamic>>{};
    final live = <String>{};
    for (final message in messages) {
      live.add(message.id);
      final was = previous[message.id];
      // Identity, not equality. Every mutation in the controller rebuilds the
      // list with `[...current]` and replaces one element, so an untouched
      // message is the very same object — and one that was touched is a new
      // object from `copyWith`. [Message] is immutable, so there is no case
      // where the same instance holds different fields than it did before.
      if (identical(was, message)) continue;
      final row = encode(message);
      // A message keeps the position it was first written at: re-encoding an
      // existing one must not move it to the end of the conversation.
      row[_seqField] = was == null ? seq++ : _seqOf(box, chatId, message.id);
      writes['$chatId$_sep${message.id}'] = row;
    }

    final gone = <String>[
      for (final id in previous.keys)
        if (!live.contains(id)) '$chatId$_sep$id',
    ];

    try {
      if (writes.isNotEmpty) await box.putAll(writes);
      if (gone.isNotEmpty) await box.deleteAll(gone);
      _nextSeq[chatId] = seq;
      _written[chatId] = messages;
    } catch (e) {
      debugPrint('Messages persist($chatId) failed: $e');
    }
  }

  /// The sequence a record already on disk was written with, so an edit keeps
  /// its place. Falls back to the end, which is where a record we cannot read
  /// belongs anyway.
  int _seqOf(Box<Map<dynamic, dynamic>> box, String chatId, String messageId) {
    final existing = box.get('$chatId$_sep$messageId');
    final seq = existing?[_seqField];
    return seq is int ? seq : (_nextSeq[chatId] ?? 0);
  }

  /// Erase one conversation completely.
  Future<void> deleteChat(String chatId) async {
    final box = _box;
    _written.remove(chatId);
    _nextSeq.remove(chatId);
    if (box == null) return;
    final prefix = '$chatId$_sep';
    final keys = <dynamic>[
      for (final key in box.keys)
        if (key is String && key.startsWith(prefix)) key,
    ];
    if (keys.isEmpty) return;
    try {
      await box.deleteAll(keys);
    } catch (e) {
      debugPrint('Messages delete($chatId) failed: $e');
    }
  }

  /// Erase everything (emergency wipe, and the transfer restore).
  Future<void> clear() async {
    _written.clear();
    _nextSeq.clear();
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('Messages clear failed: $e');
    }
  }

  /// Copy the one-entry-per-conversation format across, once.
  ///
  /// The old box is read and left exactly as it was. It is not deleted and not
  /// emptied: this is everybody's entire history, the new shape has never run
  /// on a real phone before this build, and a copy that stays behind costs disk
  /// and nothing else. Removing it is a later decision, taken once there is
  /// evidence rather than intent.
  Future<void> _importV1IfNeeded(Box<Map<dynamic, dynamic>> box) async {
    if (box.get(_importedKey) != null) return;
    try {
      final old = await hiveCipherProvider
          .openEncryptedBox<List<dynamic>>(HiveBoxes.messages);
      var chats = 0;
      var records = 0;
      for (final key in old.keys) {
        if (key is! String) continue;
        final raw = old.get(key);
        if (raw == null) continue;
        final writes = <String, Map<String, dynamic>>{};
        var seq = 0;
        for (final row in raw) {
          if (row is! Map) continue;
          try {
            final map = Map<String, dynamic>.from(row.cast<String, dynamic>());
            final id = map['id'];
            if (id is! String) continue;
            map[_seqField] = seq++;
            writes['$key$_sep$id'] = map;
          } catch (e) {
            debugPrint('skip corrupt v1 message in "$key": $e');
          }
        }
        if (writes.isEmpty) continue;
        await box.putAll(writes);
        chats++;
        records += writes.length;
      }
      await box.put(_importedKey, <String, dynamic>{
        'at': DateTime.now().toIso8601String(),
      });
      debugPrint('Messages: imported $records messages in $chats chats '
          'from the previous format');
    } catch (e, st) {
      // A failed import must not take the app down with it. The box stays
      // unmarked, so the next launch tries again; until one succeeds the app
      // starts with no history rather than with half of it, which is visible
      // and recoverable rather than silent and not.
      debugPrint('Messages: import from the previous format failed: $e\n$st');
    }
  }

  /// `chatId` and `messageId` out of a record key, or null if it is not one.
  static (String, String)? _split(dynamic key) {
    if (key is! String) return null;
    final at = key.indexOf(_sep);
    if (at <= 0 || at == key.length - 1) return null;
    return (key.substring(0, at), key.substring(at + 1));
  }
}
