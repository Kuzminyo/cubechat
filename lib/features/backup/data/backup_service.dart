import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/background_mode_controller.dart';
import '../../../core/util/media_storage.dart';
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
import '../../channels/data/channel_descriptions_controller.dart';
import '../../peers/data/contact_aliases_controller.dart';
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
      'media': await _collectMedia(),
    };
    return _codec.encrypt(payload, password: password);
  }

  /// Directories whose contents a conversation refers to but does not contain.
  ///
  /// Everything in Hive was already in the backup — messages, contacts, pins,
  /// the nickname, avatars, every setting. What was not is what those records
  /// *point at*: a message says "there is a photograph at this path", and the
  /// path is all that survived. Restoring on a fresh phone gave you the whole
  /// history with a grey box where every picture, voice note and sticker had
  /// been, which is not what "a backup" means to anybody.
  static const _mediaDirs = <String>[
    'cubechat-images',
    'cubechat-sent',
    'cubechat-audio',
    'cubechat-stickers',
  ];

  /// Every media file, keyed by `directory/filename`.
  ///
  /// Stored by name rather than by absolute path on purpose: the documents
  /// directory has a different absolute path on the phone this is restored
  /// onto — iOS changes it between installs of the *same* app — so an absolute
  /// path is the one thing here guaranteed not to survive the trip.
  Future<Map<String, Object?>> _collectMedia() async {
    // Newest first, across all four directories at once, so the budget below
    // keeps the pictures somebody would actually miss.
    final files = <File>[];
    for (final name in _mediaDirs) {
      final Directory dir;
      try {
        dir = await mediaDirectory(name);
      } catch (_) {
        continue;
      }
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync()) {
        if (entity is File) files.add(entity);
      }
    }
    files.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return 0;
      }
    });

    final out = <String, Object?>{};
    var budget = _maxMediaTotalBytes;
    for (final entity in files) {
      try {
        final size = entity.lengthSync();
        // A backup that refuses to be made is worse than one missing a video:
        // anything implausible for a chat attachment is skipped rather than
        // allowed to push the whole payload out of memory.
        if (size > _maxMediaBytes) continue;
        if (size > budget) continue;
        final bytes = await entity.readAsBytes();
        budget -= bytes.length;
        final base = entity.path.split(Platform.pathSeparator).last;
        // The directory name is recoverable from the file's own parent, so a
        // file found in one directory is filed back into that one.
        final dirName =
            entity.parent.path.split(Platform.pathSeparator).last;
        out['$dirName/$base'] = base64Url.encode(bytes);
      } catch (_) {
        // A file being written as the backup is read, or one the OS has
        // taken away. Skipped, not fatal.
      }
    }
    return out;
  }

  /// Per file. Photos are capped by the picker long before this; the limit is
  /// here for the pathological case, not the ordinary one.
  static const int _maxMediaBytes = 16 * 1024 * 1024;

  /// And a ceiling for the lot, which the first version of this did not have.
  ///
  /// Without one, a phone with a few hundred photographs produced a payload of
  /// several hundred megabytes: base64 adds a third, the whole thing is a
  /// single JSON string held in memory, and it is then encrypted into a second
  /// buffer beside it. The phone-to-phone transfer refuses anything over
  /// [PhoneTransferService.maxTransferBytes], so the receiver died partway
  /// through a transfer the sender had spent a minute building — which is what
  /// "the QR transfer does not work" was.
  ///
  /// Forty-eight megabytes of files is roughly sixty-four once encoded, which
  /// leaves the encrypted payload comfortably inside the transfer cap and the
  /// two buffers inside what a mid-range phone will hand out at once.
  static const int _maxMediaTotalBytes = 48 * 1024 * 1024;

  /// Put the files back where the records expect them.
  ///
  /// Written before the boxes are restored would be pointless and after is
  /// fine: nothing reads a media path until something draws it, and by then
  /// both halves are in place.
  Future<void> _restoreMedia(Object? raw) async {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String) continue;
      final slash = key.indexOf('/');
      if (slash <= 0) continue;
      final dirName = key.substring(0, slash);
      final fileName = key.substring(slash + 1);
      // Only the directories this backup writes, and only a bare filename.
      // A path arriving from a file somebody else made is not going to be
      // allowed to name a location.
      if (!_mediaDirs.contains(dirName)) continue;
      if (fileName.isEmpty ||
          fileName.contains('/') ||
          fileName.contains(r'') ||
          fileName.contains('..')) {
        continue;
      }
      try {
        final dir = await mediaDirectory(dirName);
        final file = File('${dir.path}${Platform.pathSeparator}$fileName');
        if (file.existsSync()) continue;
        await file.writeAsBytes(base64Url.decode(value), flush: true);
      } catch (_) {
        // One unwritable file does not fail a restore that has already put
        // the conversations back.
      }
    }
  }

  /// Decrypts and validates everything before replacing local state.
  Future<void> restore(
    List<int> encrypted, {
    required String password,
  }) async {
    final payload = await _codec.decrypt(encrypted, password: password);
    final prepared = _validatePayload(payload);
    // The files the records point at. Before the boxes go in, because a
    // half-restored phone that has the conversation and not the photograph is
    // the state this whole change exists to stop — and if the write fails,
    // nothing has been replaced yet.
    await _restoreMedia(payload['media']);

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
    await _warmRestoredIdentity();
  }

  /// Read back the two things a person looks at first, before returning.
  ///
  /// `invalidate` is lazy: it disposes the controller and rebuilds it when
  /// something next reads it. [NicknameController.build] returns
  /// `Anonymous` synchronously and only then opens the box, so whatever
  /// displays a name in the frame after a restore displays that placeholder —
  /// and a restore is precisely the moment somebody is watching to see whether
  /// their identity came back. It reads as "the restore lost my name".
  ///
  /// The value is in the box by now; this only makes the read happen before
  /// the restore reports success rather than after. The avatar is warmed for
  /// the same reason and with more at stake: its announcement digest is what
  /// tells every contact whether we still have a picture, and answering from
  /// an unloaded controller tells them we removed it.
  Future<void> _warmRestoredIdentity() async {
    try {
      await _ref.read(nicknameControllerProvider.notifier).loaded;
      await _ref.read(avatarProvider.notifier).shareable();
    } catch (e) {
      debugPrint('warming restored identity failed: $e');
    }
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
    _ref.invalidate(contactAliasesControllerProvider);
    _ref.invalidate(channelAvatarsControllerProvider);
    _ref.invalidate(channelDescriptionsControllerProvider);
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
