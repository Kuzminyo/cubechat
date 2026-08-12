import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

@immutable
class UserChatFolder {
  const UserChatFolder({
    required this.id,
    required this.name,
    this.chatIds = const <String>[],
  });

  final String id;
  final String name;
  final List<String> chatIds;

  bool contains(String chatId) => chatIds.contains(chatId);

  UserChatFolder copyWith({String? name, List<String>? chatIds}) =>
      UserChatFolder(
        id: id,
        name: name ?? this.name,
        chatIds: chatIds ?? this.chatIds,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'chatIds': chatIds,
      };

  static UserChatFolder? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final chatIds = raw['chatIds'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) {
      return null;
    }
    return UserChatFolder(
      id: id,
      name: name.trim(),
      chatIds: chatIds is List
          ? chatIds.whereType<String>().toSet().toList(growable: false)
          : const <String>[],
    );
  }
}

class UserChatFoldersController extends Notifier<List<UserChatFolder>> {
  static const _key = 'chats.userFolders';

  Box<dynamic>? _box;

  @override
  List<UserChatFolder> build() {
    unawaited(_load());
    return const <UserChatFolder>[];
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final raw = box.get(_key);
      if (raw is! List) return;
      final loaded = raw
          .map(UserChatFolder.fromJson)
          .whereType<UserChatFolder>()
          .toList(growable: false);
      state = loaded;
    } catch (e) {
      debugPrint('UserChatFolders load failed: $e');
    }
  }

  UserChatFolder? byId(String id) {
    for (final folder in state) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  Future<UserChatFolder> create(String name,
      {Iterable<String> chatIds = const []}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name');
    final folder = UserChatFolder(
      id: 'f${DateTime.now().microsecondsSinceEpoch}',
      name: trimmed,
      chatIds: chatIds.toSet().toList(growable: false),
    );
    state = [...state, folder];
    await _persist();
    return folder;
  }

  Future<void> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    state = [
      for (final folder in state)
        if (folder.id == id) folder.copyWith(name: trimmed) else folder,
    ];
    await _persist();
  }

  Future<void> delete(String id) async {
    state = state.where((folder) => folder.id != id).toList(growable: false);
    await _persist();
  }

  Future<void> addChat(String folderId, String chatId) async {
    state = [
      for (final folder in state)
        if (folder.id == folderId && !folder.chatIds.contains(chatId))
          folder.copyWith(chatIds: [...folder.chatIds, chatId])
        else
          folder,
    ];
    await _persist();
  }

  Future<void> removeChat(String folderId, String chatId) async {
    state = [
      for (final folder in state)
        if (folder.id == folderId)
          folder.copyWith(
            chatIds: folder.chatIds
                .where((id) => id != chatId)
                .toList(growable: false),
          )
        else
          folder,
    ];
    await _persist();
  }

  Future<void> setChats(String folderId, Iterable<String> chatIds) async {
    final ids = chatIds.toSet().toList(growable: false);
    state = [
      for (final folder in state)
        if (folder.id == folderId) folder.copyWith(chatIds: ids) else folder,
    ];
    await _persist();
  }

  Future<void> forgetChat(String chatId) async {
    state = [
      for (final folder in state)
        folder.copyWith(
          chatIds: folder.chatIds
              .where((id) => id != chatId)
              .toList(growable: false),
        ),
    ];
    await _persist();
  }

  Future<void> clear() async {
    state = const <UserChatFolder>[];
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('UserChatFolders clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, [for (final folder in state) folder.toJson()]);
    } catch (e) {
      debugPrint('UserChatFolders persist failed: $e');
    }
  }
}

final userChatFoldersControllerProvider =
    NotifierProvider<UserChatFoldersController, List<UserChatFolder>>(
  UserChatFoldersController.new,
);

final selectedUserFolderProvider = StateProvider<String?>((_) => null);
