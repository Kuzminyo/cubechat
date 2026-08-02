import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import 'messages_controller.dart';

/// How long a message survives in one conversation, as a plain duration.
///
/// Was a four-value enum (off / 1 / 7 / 30 days). Any fixed set is wrong for
/// somebody: the interesting choices are usually much shorter than a day, and
/// "a week" is nobody's threat model. Seconds carry every preset the enum had
/// plus whatever the user actually wants, and the presets survive only as
/// suggestions in the picker.
@immutable
class ChatAutoDelete {
  const ChatAutoDelete(this.seconds);

  /// Zero (and anything negative, which cannot be entered but can be decoded
  /// from a mangled store) means messages are kept.
  final int seconds;

  static const off = ChatAutoDelete(0);

  /// Offered in the picker, in order. Not a constraint — just the shortcuts.
  static const presets = <ChatAutoDelete>[
    off,
    ChatAutoDelete(60),
    ChatAutoDelete(60 * 60),
    ChatAutoDelete(24 * 60 * 60),
    ChatAutoDelete(7 * 24 * 60 * 60),
    ChatAutoDelete(30 * 24 * 60 * 60),
  ];

  /// Longest we accept, so a typo cannot set something indistinguishable from
  /// off while still reading as "on" in the UI.
  static const maxSeconds = 365 * 24 * 60 * 60;

  bool get isOn => seconds > 0;

  Duration? get duration => isOn ? Duration(seconds: seconds) : null;

  /// Decode a value stored before this was a duration.
  static ChatAutoDelete fromLegacyName(String? name) => switch (name) {
        'oneDay' => const ChatAutoDelete(24 * 60 * 60),
        'sevenDays' => const ChatAutoDelete(7 * 24 * 60 * 60),
        'thirtyDays' => const ChatAutoDelete(30 * 24 * 60 * 60),
        _ => off,
      };

  @override
  bool operator ==(Object other) =>
      other is ChatAutoDelete && other.seconds == seconds;

  @override
  int get hashCode => seconds.hashCode;
}

@immutable
class ConversationSettings {
  const ConversationSettings({
    this.autoDelete = ChatAutoDelete.off,
    this.restrictCopying = false,
  });

  static const initial = ConversationSettings();

  final ChatAutoDelete autoDelete;
  final bool restrictCopying;

  ConversationSettings copyWith({
    ChatAutoDelete? autoDelete,
    bool? restrictCopying,
  }) =>
      ConversationSettings(
        autoDelete: autoDelete ?? this.autoDelete,
        restrictCopying: restrictCopying ?? this.restrictCopying,
      );

  bool get isDefault =>
      !autoDelete.isOn && !restrictCopying;

  @override
  bool operator ==(Object other) =>
      other is ConversationSettings &&
      other.autoDelete == autoDelete &&
      other.restrictCopying == restrictCopying;

  @override
  int get hashCode => Object.hash(autoDelete, restrictCopying);
}

/// Local per-conversation privacy preferences.
///
/// Auto-delete is enforced on load, whenever the preference changes, and once
/// a minute while the app is alive. Copy restriction is consumed by message
/// surfaces so copy, forward and system-share controls disappear together.
class ConversationSettingsController
    extends Notifier<Map<String, ConversationSettings>> {
  static const _key = 'conversation_settings';

  Box<dynamic>? _box;
  Timer? _pruneTimer;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, ConversationSettings> build() {
    _pruneTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(pruneExpired()),
    );
    ref.onDispose(() => _pruneTimer?.cancel());
    unawaited(_loading = _load());
    return const <String, ConversationSettings>{};
  }

  ConversationSettings forChat(String chatId) =>
      state[chatId] ?? ConversationSettings.initial;

  Future<void> setAutoDelete(
    String chatId,
    ChatAutoDelete period,
  ) async {
    await _put(chatId, forChat(chatId).copyWith(autoDelete: period));
    await _pruneChat(chatId, period);
  }

  Future<void> setRestrictCopying(String chatId, bool restricted) =>
      _put(chatId, forChat(chatId).copyWith(restrictCopying: restricted));

  Future<void> forget(String chatId) async {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  Future<void> clear() async {
    state = const <String, ConversationSettings>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('ConversationSettings clear failed: $e');
    }
  }

  Future<void> pruneExpired() async {
    for (final entry in state.entries) {
      await _pruneChat(entry.key, entry.value.autoDelete);
    }
  }

  Future<void> _pruneChat(
    String chatId,
    ChatAutoDelete period,
  ) async {
    final lifetime = period.duration;
    if (lifetime == null) return;
    final cutoff = DateTime.now().subtract(lifetime);
    await ref
        .read(messagesControllerProvider.notifier)
        .deleteBefore(chatId, cutoff);
  }

  Future<void> _put(String chatId, ConversationSettings value) async {
    final next = {...state};
    if (value.isDefault) {
      next.remove(chatId);
    } else {
      next[chatId] = value;
    }
    state = next;
    await _persist();
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        final loaded = <String, ConversationSettings>{};
        for (final entry in raw.entries) {
          if (entry.key is! String || entry.value is! Map) continue;
          final value = entry.value as Map;
          // `autoDeleteSeconds` is what this build writes; `autoDelete` is
          // the enum name older installs stored, and is still read so an
          // existing setting is not silently switched off by an update.
          final rawSeconds = value['autoDeleteSeconds'];
          final period = rawSeconds is int
              ? ChatAutoDelete(rawSeconds.clamp(0, ChatAutoDelete.maxSeconds))
              : ChatAutoDelete.fromLegacyName(value['autoDelete'] as String?);
          final settings = ConversationSettings(
            autoDelete: period,
            restrictCopying: value['restrictCopying'] == true,
          );
          if (!settings.isDefault) loaded[entry.key as String] = settings;
        }
        if (loaded.isNotEmpty) state = {...loaded, ...state};
      }
      await pruneExpired();
    } catch (e) {
      debugPrint('ConversationSettings load failed: $e');
    }
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_key, {
        for (final entry in state.entries)
          entry.key: {
            'autoDeleteSeconds': entry.value.autoDelete.seconds,
            'restrictCopying': entry.value.restrictCopying,
          },
      });
    } catch (e) {
      debugPrint('ConversationSettings persist failed: $e');
    }
  }
}

final conversationSettingsControllerProvider = NotifierProvider<
    ConversationSettingsController, Map<String, ConversationSettings>>(
  ConversationSettingsController.new,
);
