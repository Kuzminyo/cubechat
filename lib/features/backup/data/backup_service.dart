import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ble/background_mode_controller.dart';
import 'backup_filter.dart';
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
import 'backup_file_codec.dart';
import '../../map/data/shared_map_locations_provider.dart';

class BackupService {
  BackupService(this._ref, {BackupCodec? codec})
      : _codec = codec ?? BackupCodec();

  static const payloadVersion = 1;

  final Ref _ref;
  final BackupCodec _codec;

  Future<Uint8List> create({required String password}) async {
    final payload = await _snapshot();
    payload['media'] = await _collectMedia();
    return _codec.encrypt(payload, password: password);
  }

  Future<Map<String, Object?>> _snapshot() async {
    if (_ref.exists(mapPresenceStoreProvider)) {
      await _ref.read(mapPresenceStoreProvider.notifier).flush();
    }
    final identity = await _ref.read(identityProvider.future);
    final boxes = <String, Object?>{};
    for (final name in HiveBoxes.all) {
      final dynamic box = await _openBox(name);
      final keys = (box.keys as Iterable<dynamic>).toList();
      boxes[name] = [
        for (final key in keys)
          if (backupKeeps(name, key))
            [
              _encodeValue(key),
              _encodeValue(backupValue(name, key, box.get(key))),
            ],
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
    return payload;
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
    'cubechat-inbox',
    'cubechat-outbox',
    'cubechat-circles',
    'cubechat-saved',
    'cubechat-wallpaper',
  ];

  /// Keep the legacy phone-transfer format within its existing memory budget.
  /// Exceeding it is an explicit error; only createFile supports unbounded media.
  static const int _maxMediaTotalBytes = 48 * 1024 * 1024;

  Future<Map<String, File>> _mediaFiles() async {
    final files = <String, File>{};
    for (final name in _mediaDirs) {
      final dir = await mediaDirectory(name);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final base = entity.uri.pathSegments.last;
          _validateMediaKey('$name/$base');
          files['$name/$base'] = entity;
        } else {
          // Never report a complete backup while quietly omitting a new layout.
          throw FileSystemException('unsupported media entry', entity.path);
        }
      }
    }
    return files;
  }

  Future<Map<String, Object?>> _collectMedia() async {
    final files = await _mediaFiles();
    var total = 0;
    for (final file in files.values) {
      total += await file.length();
      if (total > _maxMediaTotalBytes) {
        throw StateError(
            'Use a file backup: media exceeds the phone transfer budget');
      }
    }
    final out = <String, Object?>{};
    var remaining = _maxMediaTotalBytes;
    for (final entry in files.entries) {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in entry.value.openRead()) {
        remaining -= chunk.length;
        if (remaining < 0)
          throw StateError('Media grew beyond the transfer budget');
        bytes.add(chunk);
      }
      out[entry.key] = base64Url.encode(bytes.takeBytes());
    }
    return out;
  }

  /// Media is streamed directly into authenticated records, never base64 or a
  /// whole-gallery buffer. Metadata retains the v1 typed Hive representation.
  Future<void> createFile(File destination, {required String password}) async {
    final payload = await _snapshot();
    final files = await _mediaFiles();
    Stream<List<int>> archive() async* {
      final metadata = utf8.encode(jsonEncode(payload));
      if (metadata.length > _maxMetadataBytes) {
        throw StateError('Backup metadata exceeds the supported size');
      }
      yield BackupFileCodec.uint32(metadata.length);
      yield metadata;
      for (final entry in files.entries) {
        final before = await entry.value.stat();
        final header =
            utf8.encode(jsonEncode({'key': entry.key, 'size': before.size}));
        yield BackupFileCodec.uint32(header.length);
        yield header;
        var copied = 0;
        await for (final chunk in entry.value.openRead()) {
          copied += chunk.length;
          yield chunk;
        }
        final after = await entry.value.stat();
        if (copied != before.size ||
            after.size != before.size ||
            after.modified != before.modified) {
          throw FileSystemException(
              'Media changed during backup', entry.value.path);
        }
      }
      yield BackupFileCodec.uint32(0);
    }

    try {
      await BackupFileCodec()
          .encrypt(archive(), destination, password: password);
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  static const _maxMetadataBytes = 128 * 1024 * 1024;

  /// Authenticate the entire archive in private temporary storage before any
  /// local files, boxes, or identity are replaced. Legacy JSON still imports.
  Future<void> restoreFile(File source, {required String password}) async {
    final probe = await source.open();
    final prefix = await probe.read(8);
    await probe.close();
    if (!listEquals(prefix, BackupFileCodec.magic)) {
      if (await source.length() > 128 * 1024 * 1024) {
        throw const FormatException('legacy backup exceeds memory limit');
      }
      return restore(await source.readAsBytes(), password: password);
    }
    final temporary = await getTemporaryDirectory();
    final staging = await temporary.createTemp('cubechat-restore-');
    final clear = File('${staging.path}/archive');
    try {
      await BackupFileCodec().decrypt(source, clear, password: password);
      final input = await clear.open();
      late Map<String, dynamic> payload;
      final media = <(String, int, int)>[];
      try {
        Future<int> length() async => ByteData.sublistView(
              await BackupFileCodec.readExactly(input, 4),
            ).getUint32(0);
        final metadataSize = await length();
        if (metadataSize > _maxMetadataBytes)
          throw const FormatException('oversized metadata');
        final decoded = jsonDecode(utf8
            .decode(await BackupFileCodec.readExactly(input, metadataSize)));
        if (decoded is! Map<String, dynamic>)
          throw const FormatException('invalid metadata');
        payload = decoded;
        _validatePayload(payload);
        final seen = <String>{};
        final total = await input.length();
        while (true) {
          final headerSize = await length();
          if (headerSize == 0) break;
          if (headerSize > 4096)
            throw const FormatException('oversized file header');
          final header = jsonDecode(utf8
              .decode(await BackupFileCodec.readExactly(input, headerSize)));
          if (header is! Map<String, dynamic> ||
              header['key'] is! String ||
              header['size'] is! int) {
            throw const FormatException('invalid file header');
          }
          final key = header['key'] as String;
          final size = header['size'] as int;
          _validateMediaKey(key);
          final start = await input.position();
          if (!seen.add(key) || size < 0 || size > total - start) {
            throw const FormatException('invalid file range');
          }
          media.add((key, start, size));
          await input.setPosition(start + size);
        }
        if (await input.position() != total)
          throw const FormatException('trailing archive data');
      } finally {
        await input.close();
      }
      for (final (key, start, size) in media) {
        final parts = key.split('/');
        final dir = await mediaDirectory(parts.first);
        final target = File('${dir.path}/${parts.last}');
        final sink = target.openWrite();
        try {
          await sink.addStream(clear.openRead(start, start + size));
          await sink.flush();
        } finally {
          await sink.close();
        }
      }
      MediaPaths.forgetAll();
      await _applyPayload(payload);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  static void _validateMediaKey(String key) {
    final parts = key.split('/');
    if (parts.length != 2 ||
        !_mediaDirs.contains(parts.first) ||
        parts.last.isEmpty ||
        parts.last.contains('..') ||
        parts.last.contains(RegExp(r'[\\:\x00-\x1f]'))) {
      throw const FormatException('invalid media path');
    }
  }

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
      // The middle test was `contains(r'')` — an empty raw string, which every
      // string contains. So this rejected every file there has ever been, and
      // a restore put the conversations back and silently kept none of the
      // photos or voice notes they refer to. It was meant to be a backslash,
      // written the one way that cannot be misread as an escape.
      if (fileName.isEmpty ||
          fileName.contains('/') ||
          fileName.contains('\\') ||
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
    await _applyPayload(payload);
  }

  Future<void> _applyPayload(Map<String, dynamic> payload) async {
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
      // Match MessageStore: opening these as dynamic fails after a chat opens.
      HiveBoxes.messageRecords ||
      HiveBoxes.chatSummaries ||
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
    _ref.invalidate(mapPresenceStoreProvider);
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
