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

/// What one conversation is drawn on.
///
/// Purely local and purely cosmetic: nothing goes on the wire, so two people
/// in the same chat can each pick their own, exactly as they already can with
/// auto-delete.
@immutable
class ChatWallpaper {
  const ChatWallpaper({
    this.presetIndex,
    this.imagePath,
    this.dim = 0.35,
  });

  static const none = ChatWallpaper();

  /// Index into [presets]. Null when this is an image, or nothing at all.
  final int? presetIndex;

  /// A picture the user chose, already copied into app storage — the picker's
  /// own temporary file is collected out from under us otherwise.
  final String? imagePath;

  /// How much dark scrim goes over the top, 0..1. A photograph makes an
  /// unreadable backdrop for text at almost any brightness, so a wallpaper
  /// without a legibility layer is one people turn back off.
  final double dim;

  bool get isSet => presetIndex != null || imagePath != null;

  /// Bundled gradients, as pairs of colour values. Deliberately a handful:
  /// the point is a conversation that looks distinct at a glance, not a
  /// theming engine.
  static const presets = <List<int>>[
    [0xFF1B3A2F, 0xFF0B1A16],
    [0xFF2A1F3D, 0xFF120B1C],
    [0xFF1F2E4A, 0xFF0B1220],
    [0xFF3D2320, 0xFF1A0E0C],
    [0xFF23343A, 0xFF0C1518],
  ];

  ChatWallpaper copyWith({
    int? presetIndex,
    String? imagePath,
    double? dim,
    bool clearPreset = false,
    bool clearImage = false,
  }) =>
      ChatWallpaper(
        presetIndex: clearPreset ? null : (presetIndex ?? this.presetIndex),
        imagePath: clearImage ? null : (imagePath ?? this.imagePath),
        dim: dim ?? this.dim,
      );

  @override
  bool operator ==(Object other) =>
      other is ChatWallpaper &&
      other.presetIndex == presetIndex &&
      other.imagePath == imagePath &&
      other.dim == dim;

  @override
  int get hashCode => Object.hash(presetIndex, imagePath, dim);
}

@immutable
class ConversationSettings {
  const ConversationSettings({
    this.autoDelete = ChatAutoDelete.off,
    this.autoDeleteFrom,
    this.restrictCopying = false,
    this.peerRestrictsCopying = false,
    this.wallpaper = ChatWallpaper.none,
  });

  static const initial = ConversationSettings();

  final ChatAutoDelete autoDelete;

  /// When [autoDelete] was switched on, and therefore the oldest message it is
  /// allowed to touch.
  ///
  /// Without it, turning on "delete after an hour" deleted the last year of
  /// the conversation on the spot — every message already older than an hour
  /// was past its cutoff the instant the setting existed. That is a defensible
  /// reading of the words and a terrible reading of the intent: the switch is
  /// understood as "from now on", and its most likely use is right after
  /// saying something you would rather not leave lying around, in a chat you
  /// otherwise want to keep.
  ///
  /// Set on off→on only. Changing the period while it is already on keeps the
  /// original anchor, so shortening the timer cannot suddenly reach further
  /// back than the switch itself ever did.
  final DateTime? autoDeleteFrom;

  /// What *we* asked for in this conversation.
  final bool restrictCopying;

  /// What the person on the other end asked for.
  ///
  /// Held apart from [restrictCopying] rather than folded into it so the two
  /// cannot cancel each other: turning our own switch off must not lift their
  /// request, and their turning theirs off must not lift ours. Only the side
  /// that set a flag can clear it.
  final bool peerRestrictsCopying;

  final ChatWallpaper wallpaper;

  /// Whether copying, forwarding and sharing are off in this conversation —
  /// the question every message surface actually asks. Either side saying so
  /// is enough; it is a request about the conversation, not about one device.
  bool get copyingRestricted => restrictCopying || peerRestrictsCopying;

  ConversationSettings copyWith({
    ChatAutoDelete? autoDelete,
    DateTime? autoDeleteFrom,
    bool clearAutoDeleteFrom = false,
    bool? restrictCopying,
    bool? peerRestrictsCopying,
    ChatWallpaper? wallpaper,
  }) =>
      ConversationSettings(
        autoDelete: autoDelete ?? this.autoDelete,
        autoDeleteFrom:
            clearAutoDeleteFrom ? null : (autoDeleteFrom ?? this.autoDeleteFrom),
        restrictCopying: restrictCopying ?? this.restrictCopying,
        peerRestrictsCopying: peerRestrictsCopying ?? this.peerRestrictsCopying,
        wallpaper: wallpaper ?? this.wallpaper,
      );

  bool get isDefault =>
      !autoDelete.isOn && !copyingRestricted && !wallpaper.isSet;

  @override
  bool operator ==(Object other) =>
      other is ConversationSettings &&
      other.autoDelete == autoDelete &&
      other.autoDeleteFrom == autoDeleteFrom &&
      other.restrictCopying == restrictCopying &&
      other.peerRestrictsCopying == peerRestrictsCopying &&
      other.wallpaper == wallpaper;

  @override
  int get hashCode => Object.hash(
        autoDelete,
        autoDeleteFrom,
        restrictCopying,
        peerRestrictsCopying,
        wallpaper,
      );
}

/// Per-conversation privacy preferences.
///
/// Auto-delete and the wallpaper are local: two people in the same chat can
/// each pick their own, and nothing about either goes on the wire. The copy
/// restriction is the exception — it is a request *about the conversation*,
/// so it travels (as an `InnerPayloadType.copyRestriction` frame) and arrives
/// here as [ConversationSettings.peerRestrictsCopying]. Message surfaces read
/// [ConversationSettings.copyingRestricted], which is both sides at once, so
/// copy, forward and system-share controls disappear together whichever end
/// asked for it.
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
    final before = forChat(chatId);
    // The anchor moves only on off→on. Turning it off drops it, so switching
    // back on later starts a fresh window rather than resurrecting the reach of
    // a setting that was cancelled; changing the period while it is on keeps
    // it, so a shorter timer still cannot bite into anything older than the
    // moment the user first said yes.
    final next = period.isOn
        ? before.copyWith(
            autoDelete: period,
            autoDeleteFrom: before.autoDelete.isOn
                ? (before.autoDeleteFrom ?? DateTime.now())
                : DateTime.now(),
          )
        : before.copyWith(autoDelete: period, clearAutoDeleteFrom: true);
    await _put(chatId, next);
    await _pruneChat(chatId, period, next.autoDeleteFrom);
  }

  Future<void> setRestrictCopying(String chatId, bool restricted) =>
      _put(chatId, forChat(chatId).copyWith(restrictCopying: restricted));

  /// Record what the peer asked for. Called from the transport when their
  /// [InnerPayloadType.copyRestriction] lands — never from the UI, because
  /// this half of the setting is not ours to change.
  Future<void> setPeerRestrictsCopying(String chatId, bool restricted) =>
      _put(chatId, forChat(chatId).copyWith(peerRestrictsCopying: restricted));

  Future<void> setWallpaper(String chatId, ChatWallpaper wallpaper) =>
      _put(chatId, forChat(chatId).copyWith(wallpaper: wallpaper));

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
      await _pruneChat(
        entry.key,
        entry.value.autoDelete,
        entry.value.autoDeleteFrom,
      );
    }
  }

  Future<void> _pruneChat(
    String chatId,
    ChatAutoDelete period,
    DateTime? from,
  ) async {
    final lifetime = period.duration;
    if (lifetime == null) return;
    final cutoff = DateTime.now().subtract(lifetime);
    await ref
        .read(messagesControllerProvider.notifier)
        .deleteBefore(chatId, cutoff, since: from);
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
          // Absent for a setting saved before the anchor existed. Left null,
          // which reads as "no lower bound" and keeps those installs behaving
          // exactly as they did — the alternative, stamping them with `now`,
          // would spare messages the old build had already been deleting.
          final rawFrom = value['autoDeleteFromMs'];
          final settings = ConversationSettings(
            autoDelete: period,
            autoDeleteFrom: rawFrom is int
                ? DateTime.fromMillisecondsSinceEpoch(rawFrom)
                : null,
            restrictCopying: value['restrictCopying'] == true,
            peerRestrictsCopying: value['peerRestrictsCopying'] == true,
            wallpaper: ChatWallpaper(
              presetIndex: value['wallpaperPreset'] as int?,
              // Only the path — the bytes live in app storage, and putting a
              // picture inside the settings map would load every chat's
              // wallpaper on every read of this box.
              imagePath: value['wallpaperImage'] as String?,
              dim: (value['wallpaperDim'] as num?)?.toDouble() ?? 0.35,
            ),
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
            if (entry.value.autoDeleteFrom != null)
              'autoDeleteFromMs':
                  entry.value.autoDeleteFrom!.millisecondsSinceEpoch,
            'restrictCopying': entry.value.restrictCopying,
            'peerRestrictsCopying': entry.value.peerRestrictsCopying,
            if (entry.value.wallpaper.presetIndex != null)
              'wallpaperPreset': entry.value.wallpaper.presetIndex,
            if (entry.value.wallpaper.imagePath != null)
              'wallpaperImage': entry.value.wallpaper.imagePath,
            if (entry.value.wallpaper.isSet)
              'wallpaperDim': entry.value.wallpaper.dim,
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
