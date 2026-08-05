import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/background_mode_controller.dart';
import '../../../core/crypto/identity_service.dart';
import '../../../core/crypto/prekey_service.dart';
import '../../channels/data/channel_roster_controller.dart';
import '../../../core/identity/avatar_controller.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../channels/data/channel_controller.dart';
import '../../chat/data/conversation_settings_controller.dart';
import '../../chat/data/drafts_controller.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/data/pinned_controller.dart';
import '../../chats/data/favorites_controller.dart';
import '../../chats/data/read_markers_controller.dart';
import '../../chats/data/recent_searches_controller.dart';
import '../../files/data/file_transfer_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../channels/data/channel_avatars_controller.dart';
import '../../peers/data/peer_avatars_controller.dart';
import '../../peers/data/presence_controller.dart';
import '../../profile/data/discovery_settings_controller.dart';
import '../../profile/data/privacy_settings_controller.dart';
import '../../profile/data/relay_settings_controller.dart';
import 'backup_codec.dart';

class BackupService {
  BackupService(this._ref, {BackupCodec? codec})
      : _codec = codec ?? BackupCodec();

  static const payloadVersion = 1;

  final Ref _ref;
  final BackupCodec _codec;

  Future<Uint8List> create({required String password}) async {
    final identity = await _ref.read(identityProvider.future);
    final boxes = <String, Object?>{};
    for (final name in HiveBoxes.all) {
      final dynamic box = await _openBox(name);
      final keys = (box.keys as Iterable<dynamic>).toList();
      boxes[name] = [
        for (final key in keys) [_encodeValue(key), _encodeValue(box.get(key))],
      ];
    }
    final payload = <String, Object?>{
      'version': payloadVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'identity': {
        'x25519': base64Url.encode(identity.privateKey),
        'ed25519': base64Url.encode(identity.signPrivateKey),
      },
      'boxes': boxes,
    };
    return _codec.encrypt(payload, password: password);
  }

  /// Decrypts and validates everything before replacing local state.
  Future<void> restore(
    List<int> encrypted, {
    required String password,
  }) async {
    final payload = await _codec.decrypt(encrypted, password: password);
    final prepared = _validatePayload(payload);

    // Stop transports first so no late relay/presence write can land while the
    // boxes are being replaced.
    if (_ref.exists(messagingServiceProvider)) {
      try {
        await _ref.read(messagingServiceProvider).dispose();
      } catch (_) {}
    }
    // Let any debounced write already in flight settle before replacement.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    for (final name in HiveBoxes.all) {
      final dynamic box = await _openBox(name);
      await box.clear();
      final entries = prepared.boxes[name] ?? const [];
      for (final entry in entries) {
        await box.put(entry.$1, entry.$2);
      }
    }

    await _ref.read(identityServiceProvider).restorePrivateKeys(
          prepared.xPrivate,
          prepared.signingSeed,
        );
    if (_ref.exists(chatSessionManagerProvider)) {
      final sessions = _ref.read(chatSessionManagerProvider);
      final manager = _ref.read(chatSessionManagerProvider.notifier);
      for (final peerId in sessions.keys.toList()) {
        manager.drop(peerId);
      }
    }
    _invalidateState();
  }

  Future<dynamic> _openBox(String name) {
    return switch (name) {
      HiveBoxes.knownPeers ||
      HiveBoxes.channels =>
        hiveCipherProvider.openEncryptedBox<Map<dynamic, dynamic>>(name),
      HiveBoxes.messages ||
      HiveBoxes.relayBuffer =>
        hiveCipherProvider.openEncryptedBox<List<dynamic>>(name),
      _ => hiveCipherProvider.openEncryptedBox<dynamic>(name),
    };
  }

  _PreparedBackup _validatePayload(Map<String, dynamic> payload) {
    if (payload['version'] != payloadVersion) {
      throw const FormatException('unsupported backup payload version');
    }
    final identity = payload['identity'];
    final rawBoxes = payload['boxes'];
    if (identity is! Map || rawBoxes is! Map) {
      throw const FormatException('backup is missing identity or data');
    }
    final xPrivate = _decodeSeed(identity['x25519']);
    final signingSeed = _decodeSeed(identity['ed25519']);
    final boxes = <String, List<(dynamic, dynamic)>>{};
    for (final name in HiveBoxes.all) {
      final rawEntries = rawBoxes[name];
      if (rawEntries == null) {
        boxes[name] = const [];
        continue;
      }
      if (rawEntries is! List) {
        throw FormatException('invalid box data: $name');
      }
      final entries = <(dynamic, dynamic)>[];
      for (final rawEntry in rawEntries) {
        if (rawEntry is! List || rawEntry.length != 2) {
          throw FormatException('invalid box entry: $name');
        }
        entries.add(
          (_decodeValue(rawEntry[0]), _decodeValue(rawEntry[1])),
        );
      }
      boxes[name] = entries;
    }
    return _PreparedBackup(
      xPrivate: xPrivate,
      signingSeed: signingSeed,
      boxes: boxes,
    );
  }

  static Uint8List _decodeSeed(dynamic raw) {
    if (raw is! String) throw const FormatException('missing identity seed');
    final bytes = Uint8List.fromList(base64Url.decode(raw));
    if (bytes.length != 32) {
      throw const FormatException('invalid identity seed');
    }
    return bytes;
  }

  static Object? _encodeValue(dynamic value) {
    if (value == null) return const {'t': 'null'};
    if (value is String || value is bool || value is int || value is double) {
      return {'t': 'scalar', 'v': value};
    }
    if (value is Uint8List) {
      return {'t': 'bytes', 'v': base64Url.encode(value)};
    }
    if (value is DateTime) {
      return {'t': 'date', 'v': value.toUtc().toIso8601String()};
    }
    if (value is List) {
      return {'t': 'list', 'v': value.map(_encodeValue).toList()};
    }
    if (value is Map) {
      return {
        't': 'map',
        'v': [
          for (final entry in value.entries)
            [_encodeValue(entry.key), _encodeValue(entry.value)],
        ],
      };
    }
    throw FormatException('unsupported backup value: ${value.runtimeType}');
  }

  static dynamic _decodeValue(dynamic encoded) {
    if (encoded is! Map) throw const FormatException('invalid encoded value');
    return switch (encoded['t']) {
      'null' => null,
      'scalar' => encoded['v'],
      'bytes' => Uint8List.fromList(base64Url.decode(encoded['v'] as String)),
      'date' => DateTime.parse(encoded['v'] as String),
      'list' => (encoded['v'] as List).map(_decodeValue).toList(),
      'map' => {
          for (final pair in encoded['v'] as List)
            _decodeValue((pair as List)[0]): _decodeValue(pair[1]),
        },
      _ => throw const FormatException('unknown encoded value'),
    };
  }

  void _invalidateState() {
    _ref.invalidate(messagingServiceProvider);
    _ref.invalidate(prekeyServiceProvider);
    _ref.invalidate(identityProvider);
    _ref.invalidate(messagesControllerProvider);
    _ref.invalidate(knownPeersControllerProvider);
    _ref.invalidate(peerAvatarsControllerProvider);
    _ref.invalidate(channelAvatarsControllerProvider);
    _ref.invalidate(channelControllerProvider);
    _ref.invalidate(favoritesControllerProvider);
    _ref.invalidate(channelRosterControllerProvider);
    _ref.invalidate(recentSearchesControllerProvider);
    _ref.invalidate(readMarkersControllerProvider);
    _ref.invalidate(pinnedControllerProvider);
    _ref.invalidate(draftsControllerProvider);
    _ref.invalidate(fileTransferControllerProvider);
    _ref.invalidate(conversationSettingsControllerProvider);
    _ref.invalidate(presenceControllerProvider);
    _ref.invalidate(nicknameControllerProvider);
    _ref.invalidate(avatarProvider);
    _ref.invalidate(backgroundModeProvider);
    _ref.invalidate(discoverySettingsProvider);
    _ref.invalidate(privacySettingsProvider);
    _ref.invalidate(relaySettingsProvider);
  }
}

class _PreparedBackup {
  const _PreparedBackup({
    required this.xPrivate,
    required this.signingSeed,
    required this.boxes,
  });

  final Uint8List xPrivate;
  final Uint8List signingSeed;
  final Map<String, List<(dynamic, dynamic)>> boxes;
}

final backupServiceProvider = Provider<BackupService>(BackupService.new);
