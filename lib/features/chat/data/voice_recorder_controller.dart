import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/util/media_storage.dart';
import 'package:record/record.dart';

import '../../../core/audio/opus_codec.dart';
import '../../../core/util/audio_session.dart';
import '../../../core/util/debug_log.dart';

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

/// A finished recording: where it is, what it is, how long, and its shape.
typedef VoiceRecording = ({
  String path,
  String mime,
  int durationMs,
  List<double> envelope,
});

/// Owns the `record` plugin instance, manages permissions, and exposes
/// start/stop with a Riverpod-watchable state. One recorder at a time —
/// starting a fresh recording cancels any in flight.
class VoiceRecorderController extends Notifier<VoiceRecordingState> {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;

  /// The Opus note being built from the microphone stream, when this
  /// recording is one. Null for the AAC fallback - see [start].
  OpusNoteWriter? _opus;
  StreamSubscription<Uint8List>? _pcmSub;
  Completer<void>? _pcmDone;

  StreamSubscription<Amplitude>? _ampSub;
  final List<double> _levels = <double>[];

  /// The whole recording's loudness envelope, unlike [_levels] which is a
  /// rolling window. The live strip only ever shows the last moment, but the
  /// trim editor has to draw the entire clip to let someone pick a range in
  /// it — the rolling buffer would show only the tail.
  final List<double> _envelope = <double>[];

  /// How many bars of history the waveform keeps.
  static const _maxLevels = 48;

  /// Ceiling on the full envelope: at one sample per 90 ms this is a bit over
  /// three minutes, far beyond any voice note worth sending over BLE. Past it
  /// the oldest samples drop, so the editor shows the most recent stretch
  /// rather than growing without bound.
  static const _maxEnvelope = 2048;

  @override
  VoiceRecordingState build() {
    ref.onDispose(() {
      _ampSub?.cancel();
      _pcmSub?.cancel();
      _opus?.discard();
      _recorder.dispose();
    });
    return VoiceRecordingState.idle;
  }

  /// One loudness value, from whichever source this recording has: the Opus
  /// writer measuring its own samples, or the plugin's amplitude callback.
  void _noteLevel(double norm) {
    _levels.add(norm);
    if (_levels.length > _maxLevels) _levels.removeAt(0);
    _envelope.add(norm);
    if (_envelope.length > _maxEnvelope) _envelope.removeAt(0);
    final started = state.startedAt;
    if (started == null) return; // stopped between events
    state = VoiceRecordingState(
      isRecording: true,
      startedAt: started,
      levels: List<double>.of(_levels),
    );
  }

  /// Subscribe to the mic's amplitude and push normalised loudness into the
  /// rolling buffer. `Amplitude.current` is dBFS (0 = loudest, ~-45+ = near
  /// silence); map that onto 0..1 with a small floor so quiet speech still
  /// shows a bar.
  void _startAmplitude() {
    _levels.clear();
    _envelope.clear();
    _ampSub?.cancel();
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 90))
        .listen((amp) {
      _noteLevel(((amp.current + 45) / 45).clamp(0.06, 1.0).toDouble());
    });
  }

  void _stopAmplitude() {
    _ampSub?.cancel();
    _ampSub = null;
    _levels.clear();
    _envelope.clear();
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
      // Stop any prior recording without committing it — and let go of its
      // encoder, which is native memory nothing else would free.
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
      _opus?.discard();
      _opus = null;
      await _pcmSub?.cancel();
      _pcmSub = null;
      // Not the cache directory: a voice note you sent is the conversation,
      // and the OS empties the cache whenever it wants space — which is why
      // your own recordings stopped playing after a day or so.
      final dir = await voiceDirectory();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      _levels.clear();
      _envelope.clear();

      // Opus, the way Telegram records a voice note: the plain microphone at
      // 48 kHz, encoded here - see `opus_voice.dart` for why here. Should the
      // codec not load on some phone, the note is still recorded, as AAC,
      // exactly as before this existed; a voice note that fails to record is
      // worse than one that sounds a little less good.
      final opus = _openOpus();
      if (opus != null) {
        _opus = opus;
        _currentPath = '${dir.path}/rec-$stamp.opus';
        opus.onLevel = _noteLevel;
        final done = Completer<void>();
        _pcmDone = done;
        final pcm = await _recorder.startStream(AudioSession.voiceStream);
        _pcmSub = pcm.listen(
          opus.add,
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object e) {
            DebugLog.instance.log('VOICE', 'microphone stream: $e');
            if (!done.isCompleted) done.complete();
          },
        );
      } else {
        _currentPath = '${dir.path}/rec-$stamp.m4a';
        await _recorder.start(
          AudioSession.voiceRecord,
          path: _currentPath!,
        );
        _startAmplitude();
      }
      state = VoiceRecordingState(
        isRecording: true,
        startedAt: DateTime.now(),
      );
      return true;
    } catch (e, st) {
      debugPrint('voice start failed: $e\n$st');
      // A microphone that would not open must not leave an encoder behind for
      // the next stop() to finish.
      _opus?.discard();
      _opus = null;
      await _pcmSub?.cancel();
      _pcmSub = null;
      state = VoiceRecordingState(
        isRecording: false,
        startedAt: null,
        error: '$e',
      );
      return false;
    }
  }

  OpusNoteWriter? _openOpus() {
    try {
      return OpusNoteWriter();
    } catch (e) {
      DebugLog.instance.log('VOICE', 'opus unavailable, recording AAC: $e');
      return null;
    }
  }

  /// Stop recording and return the file path, its mime type, the measured
  /// duration and the loudness envelope. Null when nothing was recording or
  /// the file ended up empty.
  Future<VoiceRecording?> stop() async {
    final started = state.startedAt;
    final path = _currentPath;
    _currentPath = null;
    final opus = _opus;
    _opus = null;
    if (opus != null) {
      state = VoiceRecordingState.idle;
      return _finishOpus(opus, path, started);
    }
    // Copied before the buffers are cleared: the trim editor outlives the
    // recording and needs the envelope to draw what was captured.
    final envelope = List<double>.of(_envelope);
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
      final durationMs = DateTime.now()
          .difference(started)
          .inMilliseconds
          .clamp(0, 0xFFFFFFFF);
      return (
        path: finalPath,
        mime: 'audio/aac',
        durationMs: durationMs,
        envelope: envelope,
      );
    } catch (e, st) {
      debugPrint('voice stop failed: $e\n$st');
      return null;
    }
  }

  /// Close the microphone, let the last chunk it had in flight arrive, and
  /// write the note.
  Future<VoiceRecording?> _finishOpus(
    OpusNoteWriter opus,
    String? path,
    DateTime? started,
  ) async {
    try {
      await _recorder.stop();
      await _pcmDone?.future.timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {},
      );
      await _pcmSub?.cancel();
      _pcmSub = null;
      _pcmDone = null;
      // The writer measured every sample, so this is the note's real length
      // rather than the time between two taps.
      final durationMs = opus.duration.inMilliseconds;
      final envelope = List<double>.of(_envelope);
      _levels.clear();
      _envelope.clear();
      if (started == null || path == null || durationMs < 100) {
        opus.discard();
        return null;
      }
      final bytes = opus.finish().encode();
      await File(path).writeAsBytes(bytes, flush: true);
      DebugLog.instance.log(
        'VOICE',
        'recorded ${durationMs}ms of opus, ${bytes.length} bytes',
      );
      return (
        path: path,
        mime: OpusVoice.mime,
        durationMs: durationMs,
        envelope: envelope,
      );
    } catch (e, st) {
      debugPrint('voice stop (opus) failed: $e\n$st');
      return null;
    }
  }

  /// Abort the current recording and delete the file.
  Future<void> cancel() async {
    final path = _currentPath;
    _currentPath = null;
    _opus?.discard();
    _opus = null;
    await _pcmSub?.cancel();
    _pcmSub = null;
    _pcmDone = null;
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
