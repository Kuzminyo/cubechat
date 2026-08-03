import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

enum FileTransferDirection { outgoing, incoming }

enum FileTransferStatus {
  queued,
  transferring,
  paused,
  completed,
  failed,
  canceled,
}

@immutable
class FileTransferTask {
  const FileTransferTask({
    required this.id,
    required this.chatId,
    required this.fileName,
    this.messageId,
    required this.filePath,
    required this.mime,
    required this.bytesTotal,
    required this.completedUnits,
    required this.totalUnits,
    required this.direction,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.error,
  });

  final String id;
  final String chatId;
  final String fileName;
  final String? messageId;
  final String filePath;
  final String mime;
  final int bytesTotal;
  final int completedUnits;
  final int totalUnits;
  final FileTransferDirection direction;
  final FileTransferStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? error;

  double get progress => totalUnits <= 0
      ? (status == FileTransferStatus.completed ? 1 : 0)
      : (completedUnits / totalUnits).clamp(0.0, 1.0);

  bool get active =>
      status == FileTransferStatus.transferring ||
      status == FileTransferStatus.queued ||
      status == FileTransferStatus.paused;

  FileTransferTask copyWith({
    String? filePath,
    int? bytesTotal,
    int? completedUnits,
    int? totalUnits,
    FileTransferStatus? status,
    DateTime? updatedAt,
    String? error,
    bool clearError = false,
  }) =>
      FileTransferTask(
        id: id,
        chatId: chatId,
        fileName: fileName,
        messageId: messageId,
        filePath: filePath ?? this.filePath,
        mime: mime,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        completedUnits: completedUnits ?? this.completedUnits,
        totalUnits: totalUnits ?? this.totalUnits,
        direction: direction,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        error: clearError ? null : error ?? this.error,
      );
}

class FileTransferController extends Notifier<Map<String, FileTransferTask>> {
  static const _key = 'file_transfers_v1';

  Box<dynamic>? _box;
  Future<void>? _loading;
  Timer? _persistTimer;
  final Map<String, Completer<void>> _resumeSignals = {};

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, FileTransferTask> build() {
    ref.onDispose(() {
      _persistTimer?.cancel();
      for (final signal in _resumeSignals.values) {
        if (!signal.isCompleted) signal.complete();
      }
    });
    unawaited(_loading = _load());
    return const {};
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      final raw = _box?.get(_key);
      if (raw is! List) return;
      final restored = <String, FileTransferTask>{};
      for (final value in raw) {
        if (value is! Map) continue;
        final task = _decode(value);
        if (task == null) continue;
        final status = task.active ? FileTransferStatus.queued : task.status;
        restored[task.id] = task.copyWith(status: status);
      }
      state = {...restored, ...state};
    } catch (e) {
      debugPrint('FileTransferController load failed: $e');
    }
  }

  void register(FileTransferTask task) {
    state = {...state, task.id: task};
    _schedulePersist();
  }

  void setStatus(
    String id,
    FileTransferStatus status, {
    String? error,
  }) {
    final task = state[id];
    if (task == null) return;
    state = {
      ...state,
      id: task.copyWith(
        status: status,
        error: error,
        clearError: error == null,
      ),
    };
    if (status != FileTransferStatus.paused) {
      _release(id);
    }
    _schedulePersist();
  }

  void setProgress(String id, int completed, int total) {
    final task = state[id];
    if (task == null) return;
    state = {
      ...state,
      id: task.copyWith(
        completedUnits: completed,
        totalUnits: total,
        status: completed >= total
            ? FileTransferStatus.completed
            : FileTransferStatus.transferring,
        clearError: true,
      ),
    };
    _schedulePersist();
  }

  void complete(
    String id, {
    String? filePath,
    int? bytesTotal,
  }) {
    final task = state[id];
    if (task == null) return;
    state = {
      ...state,
      id: task.copyWith(
        filePath: filePath,
        bytesTotal: bytesTotal,
        completedUnits: task.totalUnits,
        status: FileTransferStatus.completed,
        clearError: true,
      ),
    };
    _release(id);
    _schedulePersist();
  }

  void pause(String id) {
    final task = state[id];
    if (task == null || !task.active) return;
    setStatus(id, FileTransferStatus.paused);
    _resumeSignals.putIfAbsent(id, Completer<void>.new);
  }

  void resume(String id) {
    final task = state[id];
    if (task == null) return;
    setStatus(id, FileTransferStatus.queued);
    _release(id);
  }

  void cancel(String id) => setStatus(id, FileTransferStatus.canceled);

  Future<bool> waitUntilRunnable(String id) async {
    while (true) {
      final task = state[id];
      if (task == null || task.status == FileTransferStatus.canceled) {
        return false;
      }
      if (task.status != FileTransferStatus.paused) return true;
      final signal = _resumeSignals.putIfAbsent(id, Completer<void>.new);
      await signal.future;
    }
  }

  Future<void> remove(String id) async {
    _release(id);
    state = {...state}..remove(id);
    await _persist();
  }

  Future<void> clearFinished() async {
    state = {
      for (final entry in state.entries)
        if (entry.value.active) entry.key: entry.value,
    };
    await _persist();
  }

  Future<void> clearAll() async {
    await loaded;
    state = const {};
    _persistTimer?.cancel();
    await _box?.delete(_key);
  }

  void _release(String id) {
    final signal = _resumeSignals.remove(id);
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 250), _persist);
  }

  Future<void> _persist() async {
    if (_box == null) await loaded;
    await _box?.put(_key, state.values.map(_encode).toList());
  }

  static Map<String, Object?> _encode(FileTransferTask task) => {
        'id': task.id,
        'chatId': task.chatId,
        'fileName': task.fileName,
        if (task.messageId != null) 'messageId': task.messageId,
        'filePath': task.filePath,
        'mime': task.mime,
        'bytesTotal': task.bytesTotal,
        'completedUnits': task.completedUnits,
        'totalUnits': task.totalUnits,
        'direction': task.direction.name,
        'status': task.status.name,
        'createdAt': task.createdAt.toIso8601String(),
        'updatedAt': task.updatedAt.toIso8601String(),
        if (task.error != null) 'error': task.error,
      };

  static FileTransferTask? _decode(Map<dynamic, dynamic> value) {
    try {
      return FileTransferTask(
        id: value['id'] as String,
        chatId: value['chatId'] as String,
        fileName: value['fileName'] as String,
        filePath: value['filePath'] as String? ?? '',
        mime: value['mime'] as String? ?? 'application/octet-stream',
        bytesTotal: value['bytesTotal'] as int? ?? 0,
        messageId: value['messageId'] as String?,
        completedUnits: value['completedUnits'] as int? ?? 0,
        totalUnits: value['totalUnits'] as int? ?? 0,
        direction: FileTransferDirection.values.byName(
          value['direction'] as String,
        ),
        status: FileTransferStatus.values.byName(value['status'] as String),
        createdAt: DateTime.parse(value['createdAt'] as String),
        updatedAt: DateTime.parse(value['updatedAt'] as String),
        error: value['error'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

final fileTransferControllerProvider =
    NotifierProvider<FileTransferController, Map<String, FileTransferTask>>(
  FileTransferController.new,
);
