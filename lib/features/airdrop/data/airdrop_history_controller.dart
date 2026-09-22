import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/nearby_offer.dart';
import '../domain/airdrop_rules.dart';
import '../domain/airdrop_transfer.dart';

enum AirDropOutcome { received, sent, declined, cancelled, failed, partial }

@immutable
class AirDropHistoryFile {
  const AirDropHistoryFile({
    required this.name,
    required this.size,
    required this.mime,
    this.path,
    this.deleted = false,
  });

  final String name;
  final int size;
  final String mime;

  /// Where a received file was kept. Null for a sent one: no copy is kept.
  final String? path;
  final bool deleted;

  AirDropHistoryFile deletedCopy() => AirDropHistoryFile(
        name: name,
        size: size,
        mime: mime,
        path: path,
        deleted: true,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'mime': mime,
        if (path != null) 'path': path,
        if (deleted) 'deleted': true,
      };

  static AirDropHistoryFile? fromJson(Map<dynamic, dynamic> json) {
    final name = json['name'];
    final size = json['size'];
    final mime = json['mime'];
    if (name is! String || size is! int || mime is! String) return null;
    return AirDropHistoryFile(
      name: name,
      size: size,
      mime: mime,
      path: json['path'] as String?,
      deleted: json['deleted'] == true,
    );
  }
}

@immutable
class AirDropHistoryEntry {
  const AirDropHistoryEntry({
    required this.id,
    required this.peerHex,
    required this.peerName,
    required this.direction,
    required this.at,
    required this.outcome,
    required this.files,
    this.reason,
  });

  /// A finished transfer as a history line. Sent files keep no path.
  factory AirDropHistoryEntry.of(AirDropTransfer t, DateTime at) {
    final incoming = t.direction == AirDropDirection.incoming;
    return AirDropHistoryEntry(
      id: t.id,
      peerHex: t.peerHex,
      peerName: t.peerName,
      direction: t.direction,
      at: at,
      reason: t.phase == AirDropPhase.declined ? t.reason : null,
      outcome: switch (t.phase) {
        AirDropPhase.done =>
          incoming ? AirDropOutcome.received : AirDropOutcome.sent,
        AirDropPhase.partial => AirDropOutcome.partial,
        AirDropPhase.declined => AirDropOutcome.declined,
        AirDropPhase.cancelled => AirDropOutcome.cancelled,
        _ => AirDropOutcome.failed,
      },
      files: [
        for (final f in t.files)
          AirDropHistoryFile(
            name: f.name,
            size: f.size,
            mime: f.mime,
            path: incoming && f.done ? f.path : null,
          ),
      ],
    );
  }

  final String id;
  final String peerHex;
  final String peerName;
  final AirDropDirection direction;
  final DateTime at;
  final AirDropOutcome outcome;
  final NearbyDeclineReason? reason;
  final List<AirDropHistoryFile> files;

  AirDropHistoryEntry withFiles(List<AirDropHistoryFile> files) =>
      AirDropHistoryEntry(
        id: id,
        peerHex: peerHex,
        peerName: peerName,
        direction: direction,
        at: at,
        outcome: outcome,
        reason: reason,
        files: files,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'peer': peerHex,
        'name': peerName,
        'dir': direction.name,
        'at': at.millisecondsSinceEpoch,
        'outcome': outcome.name,
        if (reason != null) 'reason': reason!.name,
        'files': [for (final f in files) f.toJson()],
      };

  static AirDropHistoryEntry? fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    final peer = json['peer'];
    final name = json['name'];
    final at = json['at'];
    final direction = AirDropDirection.values.asNameMap()[json['dir']];
    final outcome = AirDropOutcome.values.asNameMap()[json['outcome']];
    final rawFiles = json['files'];
    if (id is! String ||
        peer is! String ||
        name is! String ||
        at is! int ||
        direction == null ||
        outcome == null ||
        rawFiles is! List) {
      return null;
    }
    return AirDropHistoryEntry(
      id: id,
      peerHex: peer,
      peerName: name,
      direction: direction,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      outcome: outcome,
      reason: NearbyDeclineReason.values.asNameMap()[json['reason']],
      files: [
        for (final f in rawFiles)
          if (f is Map) AirDropHistoryFile.fromJson(f),
      ].whereType<AirDropHistoryFile>().toList(),
    );
  }
}

/// AirDrop's history both ways, newest first, the last two hundred.
///
/// In the encrypted settings box under a key the backup skips — see
/// `backup_filter.dart`. "Clear history" clears this list only; received
/// files stay where they are.
class AirDropHistoryController extends Notifier<List<AirDropHistoryEntry>> {
  static const storageKey = 'airdrop.history.v1';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  List<AirDropHistoryEntry> build() {
    unawaited(_loading = _load());
    return const [];
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(storageKey);
      if (raw is! List) return;
      final restored = [
        for (final row in raw)
          if (row is Map) AirDropHistoryEntry.fromJson(row),
      ].whereType<AirDropHistoryEntry>();
      state = [...state, ...restored].take(AirDropRules.historyCap).toList();
    } catch (e) {
      debugPrint('AirDropHistoryController load failed: $e');
    }
  }

  void add(AirDropHistoryEntry entry) {
    state = [entry, ...state.where((e) => e.id != entry.id)]
        .take(AirDropRules.historyCap)
        .toList();
    unawaited(save(state));
  }

  void markDeleted(String path) {
    state = [
      for (final e in state)
        e.files.any((f) => f.path == path)
            ? e.withFiles([
                for (final f in e.files) f.path == path ? f.deletedCopy() : f,
              ])
            : e,
    ];
    unawaited(save(state));
  }

  Future<void> clear() async {
    state = const [];
    await save(state);
  }

  /// Overridden in tests that keep history in memory.
  @protected
  Future<void> save(List<AirDropHistoryEntry> entries) async {
    if (_box == null) await loaded;
    await _box?.put(storageKey, [for (final e in entries) e.toJson()]);
  }
}

final airdropHistoryProvider =
    NotifierProvider<AirDropHistoryController, List<AirDropHistoryEntry>>(
  AirDropHistoryController.new,
);
