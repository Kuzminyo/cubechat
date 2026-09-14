import 'dart:async';

/// Per-recording handshakes: Finalize may arrive without a Start when native
/// capture fails. It must release the caller instead of waiting forever.
class RecordingCompletion {
  final _started = Completer<bool>();
  final _finished = Completer<void>();
  Future<bool> get started => _started.future;
  Future<void> get finished => _finished.future;
  void start() {
    if (!_started.isCompleted) _started.complete(true);
  }
  void finish() {
    if (!_started.isCompleted) _started.complete(false);
    if (!_finished.isCompleted) _finished.complete();
  }
}

