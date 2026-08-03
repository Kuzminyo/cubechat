import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/crypto/identity_service.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

@immutable
class ChannelMember {
  const ChannelMember({
    required this.id,
    required this.name,
    required this.isAdmin,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final bool isAdmin;
  final DateTime lastSeen;

  ChannelMember copyWith({String? name, bool? isAdmin, DateTime? lastSeen}) =>
      ChannelMember(
        id: id,
        name: name ?? this.name,
        isAdmin: isAdmin ?? this.isAdmin,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

/// Locally verified roster for every joined channel.
///
/// A shared-key channel has no server-side membership list. The roster grows
/// only from signed channel traffic and signed 1:1 invitations, so an arbitrary
/// mesh relay cannot invent a visible participant.
class ChannelRosterController
    extends Notifier<Map<String, Map<String, ChannelMember>>> {
  static const _key = 'channel_rosters_v2';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, Map<String, ChannelMember>> build() {
    unawaited(_loading = _load());
    return const {};
  }

  List<ChannelMember> membersFor(String channel) {
    final members = state[channel]?.values.toList() ?? <ChannelMember>[];
    members.sort((a, b) {
      if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return members;
  }

  bool isAdmin(String channel, String memberId) =>
      state[channel]?[memberId]?.isAdmin ?? false;

  Future<ChannelMember> ensureSelf(
    String channel, {
    bool adminWhenFirst = false,
  }) async {
    final identity = await ref.read(identityProvider.future);
    final id = _fingerprint(identity.signPublicKey);
    final existing = state[channel]?[id];
    final member = ChannelMember(
      id: id,
      name: ref.read(nicknameControllerProvider),
      isAdmin: existing?.isAdmin ??
          (adminWhenFirst && (state[channel]?.isEmpty ?? true)),
      lastSeen: DateTime.now(),
    );
    await record(channel, member);
    return member;
  }

  Future<void> record(String channel, ChannelMember member) async {
    final current = state[channel] ?? const <String, ChannelMember>{};
    final old = current[member.id];
    final merged = old == null
        ? member
        : member.copyWith(
            isAdmin: old.isAdmin || member.isAdmin,
            name: member.name.trim().isEmpty ? old.name : member.name,
          );
    state = {
      ...state,
      channel: {...current, member.id: merged},
    };
    await _persist();
  }

  Future<void> setAdmin(
    String channel,
    String memberId,
    bool admin,
  ) async {
    final current = state[channel];
    final member = current?[memberId];
    if (current == null || member == null || member.isAdmin == admin) return;
    state = {
      ...state,
      channel: {...current, memberId: member.copyWith(isAdmin: admin)},
    };
    await _persist();
  }

  Future<void> forget(String channel) async {
    if (!state.containsKey(channel)) return;
    state = {...state}..remove(channel);
    await _persist();
  }

  Future<void> clear() async {
    state = const {};
    await _box?.delete(_key);
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final raw = box.get(_key);
      if (raw is! Map) return;
      final loaded = <String, Map<String, ChannelMember>>{};
      for (final channelEntry in raw.entries) {
        if (channelEntry.key is! String || channelEntry.value is! Map) continue;
        final members = <String, ChannelMember>{};
        for (final memberEntry in (channelEntry.value as Map).entries) {
          if (memberEntry.key is! String || memberEntry.value is! Map) continue;
          final data = memberEntry.value as Map;
          final seen = DateTime.tryParse(data['lastSeen'] as String? ?? '');
          if (seen == null) continue;
          members[memberEntry.key as String] = ChannelMember(
            id: memberEntry.key as String,
            name: data['name'] as String? ?? 'Member',
            isAdmin: data['admin'] as bool? ?? false,
            lastSeen: seen,
          );
        }
        loaded[channelEntry.key as String] = members;
      }
      state = {...loaded, ...state};
    } catch (error) {
      debugPrint('Channel roster load failed: $error');
    }
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) return;
    await box.put(_key, {
      for (final channel in state.entries)
        channel.key: {
          for (final member in channel.value.entries)
            member.key: {
              'name': member.value.name,
              'admin': member.value.isAdmin,
              'lastSeen': member.value.lastSeen.toIso8601String(),
            },
        },
    });
  }

  static String _fingerprint(Uint8List bytes) => bytes
      .take(8)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}

final channelRosterControllerProvider = NotifierProvider<
    ChannelRosterController,
    Map<String, Map<String, ChannelMember>>>(ChannelRosterController.new);
