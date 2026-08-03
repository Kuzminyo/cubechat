import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What is playing, if anything.
@immutable
class VoicePlayback {
  const VoicePlayback({
    this.messageId,
    this.chatId,
    this.chatTitle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.speed = 1.0,
  });

  static const idle = VoicePlayback();

  /// Null when nothing has been started, or after the bar is dismissed.
  final String? messageId;

  /// Where to go back to when the mini player is tapped.
  final String? chatId;
  final String? chatTitle;

  final Duration position;
  final Duration duration;
  final bool playing;
  final double speed;

  bool get isActive => messageId != null;

  bool isCurrent(String id) => messageId == id;

  double get progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  VoicePlayback copyWith({
    String? messageId,
    String? chatId,
    String? chatTitle,
    Duration? position,
    Duration? duration,
    bool? playing,
    double? speed,
  }) =>
      VoicePlayback(
        messageId: messageId ?? this.messageId,
        chatId: chatId ?? this.chatId,
        chatTitle: chatTitle ?? this.chatTitle,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playing: playing ?? this.playing,
        speed: speed ?? this.speed,
      );
}

/// The one voice message the app is playing, wherever the user has wandered to.
///
/// Playback used to belong to the bubble: every [VoiceBubble] owned an
/// `AudioPlayer` and disposed it with the widget. That is fine until you scroll
/// the message off screen or leave the chat — both of which silently killed the
/// audio mid-sentence, and leaving is exactly what people do while listening.
/// The player outlives the widget now, so the only thing that stops it is
/// asking it to stop.
///
/// A single player rather than one per message, deliberately: two voice notes
/// talking over each other is never what was meant, and starting a second one
/// is the clearest possible way of saying you are done with the first.
class VoicePlaybackController extends Notifier<VoicePlayback> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _doneSub;

  /// Speeds the pill cycles through. Anything below 1 is a novelty on speech
  /// and anything above 2 is unintelligible.
  static const speeds = <double>[1.0, 1.5, 2.0];

  @override
  VoicePlayback build() {
    ref.onDispose(() {
      _posSub?.cancel();
      _durSub?.cancel();
      _doneSub?.cancel();
      _player?.dispose();
    });
    return VoicePlayback.idle;
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;

    final player = AudioPlayer();
    _posSub = player.onPositionChanged.listen((d) {
      state = state.copyWith(position: d);
    });
    _durSub = player.onDurationChanged.listen((d) {
      if (d > Duration.zero) state = state.copyWith(duration: d);
    });
    _doneSub = player.onPlayerComplete.listen((_) {
      // Finished means finished: the bar goes away on its own.
      //
      // It first stayed put, on the theory that you might want to replay it.
      // In practice a bar that outlives what it was reporting is just something
      // to dismiss, and it sits over the header of whatever screen you moved
      // on to. Nothing advances to the next voice note either — messages
      // playing themselves one after another is a thing you ask for, not
      // something that should start happening because you tapped one.
      state = VoicePlayback(speed: state.speed);
    });
    return _player = player;
  }

  /// Start [messageId], or pause/resume it when it is already the current one.
  Future<void> toggle({
    required String messageId,
    required String path,
    required String chatId,
    required String chatTitle,
    Duration? knownDuration,
  }) async {
    if (!File(path).existsSync()) return;
    final player = _ensurePlayer();

    if (state.isCurrent(messageId)) {
      if (state.playing) {
        await player.pause();
        state = state.copyWith(playing: false);
      } else {
        await player.resume();
        state = state.copyWith(playing: true);
      }
      return;
    }

    // A different message: replace rather than layer.
    await player.stop();
    state = VoicePlayback(
      messageId: messageId,
      chatId: chatId,
      chatTitle: chatTitle,
      duration: knownDuration ?? Duration.zero,
      playing: true,
      speed: state.speed,
    );
    await player.setPlaybackRate(state.speed);
    await player.play(DeviceFileSource(path));
  }

  /// Play/pause whatever is already loaded.
  ///
  /// Separate from [toggle] because the mini player has no message to name —
  /// it never starts anything, it only works the thing already going.
  Future<void> togglePlayPause() async {
    final player = _player;
    if (!state.isActive || player == null) return;
    if (state.playing) {
      await player.pause();
      state = state.copyWith(playing: false);
    } else {
      await player.resume();
      state = state.copyWith(playing: true);
    }
  }

  Future<void> seekTo(Duration position) async {
    if (!state.isActive) return;
    await _player?.seek(position);
    state = state.copyWith(position: position);
  }

  Future<void> seekFraction(double fraction) =>
      seekTo(Duration(
        milliseconds:
            (state.duration.inMilliseconds * fraction.clamp(0.0, 1.0)).round(),
      ));

  Future<void> cycleSpeed() async {
    final next = speeds[(speeds.indexOf(state.speed) + 1) % speeds.length];
    state = state.copyWith(speed: next);
    await _player?.setPlaybackRate(next);
  }

  /// Dismiss the bar entirely.
  Future<void> stop() async {
    await _player?.stop();
    state = VoicePlayback(speed: state.speed);
  }
}

final voicePlaybackControllerProvider =
    NotifierProvider<VoicePlaybackController, VoicePlayback>(
  VoicePlaybackController.new,
);
