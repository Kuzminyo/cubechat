import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// In-flight voice-message recording state. The UI watches this to show the
/// red dot + elapsed-time readout while the user holds the mic button.
@immutable
class VoiceRecordingState {
  const VoiceRecordingState({
    required this.isRecording,
    required this.startedAt,
    this.error,
    this.levels = const <double>[],
  });
  final bool isRecording;
  final DateTime? startedAt;
  final String? error;

  /// Rolling buffer of recent input loudness, 0..1, newest last. Drives the
  /// live waveform while recording. Empty when idle.
  final List<double> levels;

  static const idle = VoiceRecordingState(isRecording: false, startedAt: null);
}

/// Owns the `record` plugin instance, manages permissions, and exposes
/// start/stop with a Riverpod-watchable state. One recorder at a time —
/// starting a fresh recording cancels any in flight.
class VoiceRecorderController extends Notifier<VoiceRecordingState> {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;

  StreamSubscription<Amplitude>? _ampSub;
  final List<double> _levels = <double>[];

  /// How many bars of history the waveform keeps.
  static const _maxLevels = 48;

  @override
  VoiceRecordingState build() {
    ref.onDispose(() {
      _ampSub?.cancel();
      _recorder.dispose();
    });
    return VoiceRecordingState.idle;
  }

  /// Subscribe to the mic's amplitude and push normalised loudness into the
  /// rolling buffer. `Amplitude.current` is dBFS (0 = loudest, ~-45+ = near
  /// silence); map that onto 0..1 with a small floor so quiet speech still
  /// shows a bar.
  void _startAmplitude() {
    _levels.clear();
    _ampSub?.cancel();
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 90))
        .listen((amp) {
      final norm = ((amp.current + 45) / 45).clamp(0.06, 1.0);
      _levels.add(norm.toDouble());
      if (_levels.length > _maxLevels) _levels.removeAt(0);
      final started = state.startedAt;
      if (started == null) return; // stopped between events
      state = VoiceRecordingState(
        isRecording: true,
        startedAt: started,
        levels: List<double>.of(_levels),
      );
    });
  }

  void _stopAmplitude() {
    _ampSub?.cancel();
    _ampSub = null;
    _levels.clear();
  }

  /// Begin a new recording. Returns true if recording actually started.
  /// On permission denial / hardware failure, leaves the state with an
  /// `error` set so the UI can surface it.
  Future<bool> start() async {
    try {
      if (!await _recorder.hasPermission()) {
        state = const VoiceRecordingState(
          isRecording: false,
          startedAt: null,
          error: 'microphone permission denied',
        );
        return false;
      }
      // Stop any prior recording without committing it.
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/cubechat/audio',
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final path = '${dir.path}/rec-$stamp.m4a';
      _currentPath = path;
      await _recorder.start(
        const RecordConfig(
          // AAC inside an MP4 container — universally playable, ~16-32kbps
          // suffices for voice. Default bit rate is plenty for clarity.
          encoder: AudioEncoder.aacLc,
          numChannels: 1,
          sampleRate: 22050,
          bitRate: 24000,
        ),
        path: path,
      );
      state = VoiceRecordingState(
        isRecording: true,
        startedAt: DateTime.now(),
      );
      _startAmplitude();
      return true;
    } catch (e, st) {
      debugPrint('voice start failed: $e\n$st');
      state = VoiceRecordingState(
        isRecording: false,
        startedAt: null,
        error: '$e',
      );
      return false;
    }
  }

  /// Stop recording and return the file path + measured duration. Returns
  /// null when nothing was recording or the file ended up empty.
  Future<({String path, int durationMs})?> stop() async {
    final started = state.startedAt;
    final path = _currentPath;
    _currentPath = null;
    _stopAmplitude();
    state = VoiceRecordingState.idle;
    if (started == null) return null;
    try {
      final resolvedPath = await _recorder.stop();
      final finalPath = resolvedPath ?? path;
      if (finalPath == null) return null;
      final file = File(finalPath);
      if (!await file.exists() || (await file.length()) < 100) {
        // Less than 100 bytes = essentially silence + container header;
        // drop it so we don't send empty noise.
        return null;
      }
      final durationMs =
          DateTime.now().difference(started).inMilliseconds.clamp(0, 0xFFFFFFFF);
      return (path: finalPath, durationMs: durationMs);
    } catch (e, st) {
      debugPrint('voice stop failed: $e\n$st');
      return null;
    }
  }

  /// Abort the current recording and delete the file.
  Future<void> cancel() async {
    final path = _currentPath;
    _currentPath = null;
    _stopAmplitude();
    state = VoiceRecordingState.idle;
    try {
      await _recorder.cancel();
    } catch (_) {}
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}

final voiceRecorderProvider =
    NotifierProvider<VoiceRecorderController, VoiceRecordingState>(
  VoiceRecorderController.new,
);
