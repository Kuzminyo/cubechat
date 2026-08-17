import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/theme/colors.dart';

/// What a swipe on a chat row does.
///
/// One action, chosen by the user, rather than a tray of four the way some
/// messengers do it. A tray needs the row held open while you read it, which is
/// two gestures for something that should be one — and the whole appeal of the
/// swipe is that it is faster than a long press and a menu, both of which this
/// app already has for the full set.
enum ChatSwipeAction {
  /// The default, and the reason the gesture was asked for.
  archive(Icons.archive_rounded),

  /// Silence, without leaving or hiding anything.
  mute(Icons.notifications_off_rounded),

  pin(Icons.push_pin_rounded),

  /// Clear the unread badge without opening the conversation.
  markRead(Icons.mark_chat_read_rounded),

  /// Deliberately last, and the only one that asks before it acts.
  delete(Icons.delete_outline_rounded),

  /// No swipe at all — for anybody who keeps catching it by accident, and for
  /// whom the sideways drag between tabs matters more.
  none(Icons.block_rounded);

  const ChatSwipeAction(this.icon);

  final IconData icon;

  /// The colour of the panel revealed behind the row.
  Color get color => switch (this) {
        ChatSwipeAction.archive => AppColors.brandSecondary,
        ChatSwipeAction.mute => AppColors.warning,
        ChatSwipeAction.pin => AppColors.brandPrimary,
        ChatSwipeAction.markRead => AppColors.online,
        ChatSwipeAction.delete => AppColors.danger,
        ChatSwipeAction.none => AppColors.glassBorder,
      };

  /// Whether performing this needs a confirmation. Exactly one does: everything
  /// else here is undone by swiping again, and deleting a conversation is not.
  bool get confirms => this == ChatSwipeAction.delete;

  static ChatSwipeAction byName(String? name) => ChatSwipeAction.values
      .firstWhere((a) => a.name == name, orElse: () => ChatSwipeAction.archive);
}

class ChatSwipeActionController extends Notifier<ChatSwipeAction> {
  static const _key = 'chats.swipe_action';

  Box<dynamic>? _box;

  @override
  ChatSwipeAction build() {
    unawaited(_load());
    return ChatSwipeAction.archive;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final saved = ChatSwipeAction.byName(box.get(_key) as String?);
      if (saved != state) state = saved;
    } catch (e) {
      debugPrint('ChatSwipeAction load failed: $e');
    }
  }

  Future<void> select(ChatSwipeAction action) async {
    if (action == state) return;
    state = action;
    try {
      await _box?.put(_key, action.name);
    } catch (e) {
      debugPrint('ChatSwipeAction persist failed: $e');
    }
  }
}

final chatSwipeActionProvider =
    NotifierProvider<ChatSwipeActionController, ChatSwipeAction>(
  ChatSwipeActionController.new,
);
