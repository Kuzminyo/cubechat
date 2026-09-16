import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import 'saved_messages.dart';

/// One emoji tag per saved note, for finding things again.
///
/// Saved messages are a scratchpad — a link, a photo, a thought — and once
/// there are more than a screenful the only way back to one is search, which
/// needs you to remember a word that is in it. A tag is the other way: mark the
/// receipts with 🧾, the addresses with 📍, and the filter bar turns the pile
/// into a shelf.
///
/// Keyed by [Message.id], which for a saved note is a stable local uuid minted
/// once and never rewritten — so a tag stays on the thing it was put on across
/// restarts. Local only, like everything about the saved chat: there is no peer
/// to carry it to.
///
/// One tag, not a set. Two tags on one note is a filing system, and a filing
/// system is the thing this exists to be simpler than; if the note belongs
/// under two headings it is usually two notes.
class SavedTagsController extends Notifier<Map<String, String>> {
  static const _key = 'saved.tags';

  Box<dynamic>? _box;

  /// Whether both stores have been read. Until they have, the notebook looks
  /// empty, and reconciling against an empty notebook would delete every tag
  /// on the phone.
  bool _ready = false;

  @override
  Map<String, String> build() {
    // A tag outlives its note through every path that removes one: a single
    // delete, a selection, `/clear`, the auto-delete sweep, an Emergency Wipe.
    // Rather than a call at each of those — and the next one anybody adds —
    // the tags follow the notes: whatever is left in the notebook is what may
    // keep a tag.
    ref.listen<List<Message>>(
      messagesControllerProvider
          .select((all) => all[savedChatId] ?? const <Message>[]),
      (_, notes) {
        if (_ready) unawaited(_retain(notes));
      },
    );
    unawaited(_start());
    return const <String, String>{};
  }

  Future<void> _start() async {
    await _load();
    // And once, on the way in, for everything deleted while this provider was
    // not listening — including on a phone that has been carrying orphans
    // since before any of this existed.
    final messages = ref.read(messagesControllerProvider.notifier);
    await messages.loaded;
    // A history that failed to read is not a history that is empty, and tags
    // dropped against it would be dropped for good.
    if (messages.loadFailed) return;
    _ready = true;
    final notes =
        ref.read(messagesControllerProvider)[savedChatId] ?? const <Message>[];
    await _retain(notes);
  }

  /// Keep only the tags whose notes are still there.
  Future<void> _retain(List<Message> notes) async {
    if (state.isEmpty) return;
    final live = {for (final note in notes) note.id};
    final next = <String, String>{
      for (final entry in state.entries)
        if (live.contains(entry.key)) entry.key: entry.value,
    };
    if (next.length == state.length) return;
    state = next;
    _dropFilterOnAVanishedTag();
    await _persist();
  }

  /// A filter is a tag, and a tag can stop existing under it — the last note
  /// carrying it deleted, or untagged. Left alone, the notebook then filters
  /// itself down to nothing and every note written next lands outside the
  /// filter, which is a saved chat that looks broken rather than one that is
  /// filtered.
  void _dropFilterOnAVanishedTag() {
    final active = ref.read(savedTagFilterProvider);
    if (active == null || state.values.contains(active)) return;
    ref.read(savedTagFilterProvider.notifier).clear();
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        final loaded = <String, String>{};
        raw.forEach((k, v) {
          if (k is String && v is String && v.isNotEmpty) loaded[k] = v;
        });
        if (loaded.isNotEmpty) state = loaded;
      }
    } catch (e) {
      debugPrint('SavedTags load failed: $e');
    }
  }

  /// The tag on [messageId], or null.
  String? tagFor(String messageId) => state[messageId];

  /// Every tag in use, in a stable order, for the filter bar. Ordered by first
  /// appearance so the bar does not reshuffle itself as notes are added.
  List<String> get tagsInUse {
    final seen = <String>[];
    for (final tag in state.values) {
      if (!seen.contains(tag)) seen.add(tag);
    }
    return seen;
  }

  /// Put [tag] on [messageId], or clear it when [tag] is null — the same tap
  /// that set it takes it off, which is how the picker's "none" and re-tapping
  /// the current tag both land here.
  Future<void> setTag(String messageId, String? tag) async {
    final next = {...state};
    if (tag == null || tag.isEmpty) {
      if (next.remove(messageId) == null) return;
    } else {
      if (next[messageId] == tag) return;
      next[messageId] = tag;
    }
    state = next;
    _dropFilterOnAVanishedTag();
    await _persist();
  }

  /// Drop a tag when its note is gone, so a deleted note does not leave its tag
  /// haunting the filter bar as an entry that matches nothing.
  ///
  /// The notebook is watched for this too — see [build] — so nothing depends on
  /// every delete path remembering to call it.
  Future<void> forget(String messageId) => setTag(messageId, null);

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state);
    } catch (e) {
      debugPrint('SavedTags persist failed: $e');
    }
  }
}

final savedTagsProvider =
    NotifierProvider<SavedTagsController, Map<String, String>>(
  SavedTagsController.new,
);

/// The tag currently filtering the saved chat, or null for "show everything".
///
/// Session state, not persisted: a filter is a thing you are doing right now,
/// and coming back to the saved chat already narrowed to 🧾 with no memory of
/// setting it would be a small mystery every time.
class SavedTagFilterController extends Notifier<String?> {
  @override
  String? build() => null;

  void toggle(String tag) => state = state == tag ? null : tag;
  void clear() => state = null;
}

final savedTagFilterProvider =
    NotifierProvider<SavedTagFilterController, String?>(
  SavedTagFilterController.new,
);
