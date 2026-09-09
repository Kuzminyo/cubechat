import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/util/audio_session.dart';
import 'messages_controller.dart';

/// What is playing, if anything.
@immutable
class VoicePlayback {
  const VoicePlayback({
    this.messageId,
    this.chatId,
    this.chatTitle,
    this.sentAt,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.speed = 1.0,
    this.isCircle = false,
  });

  static const idle = VoicePlayback();

  /// Null when nothing has been started, or after the bar is dismissed.
  final String? messageId;

  /// Where to go back to when the mini player is tapped.
  final String? chatId;
  final String? chatTitle;

  /// When the note was sent. Shown beside the name, because "who" without
  /// "when" is half an answer for something that arrived while you were away.
  final DateTime? sentAt;

  final Duration position;
  final Duration duration;
  final bool playing;
  final double speed;
  final bool isCircle;

  bool get isActive => messageId != null;

  bool isCurrent(String id) => messageId == id;

  double get progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  VoicePlayback copyWith({
    String? messageId,
    String? chatId,
    String? chatTitle,
    DateTime? sentAt,
    Duration? position,
    Duration? duration,
    bool? playing,
    double? speed,
    bool? isCircle,
  }) =>
      VoicePlayback(
        messageId: messageId ?? this.messageId,
        chatId: chatId ?? this.chatId,
        chatTitle: chatTitle ?? this.chatTitle,
        sentAt: sentAt ?? this.sentAt,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playing: playing ?? this.playing,
        speed: speed ?? this.speed,
        isCircle: isCircle ?? this.isCircle,
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
  VideoPlayerController? _video;
  VideoPlayerController? get video => _video;
  int _generation = 0;
  bool _disposed = false;

  @visibleForTesting
  VideoPlayerController createVideo(String path) => VideoPlayerController.file(
        File(path),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

  Future<void> _releaseVideo() async {
    final old = _video;
    _video = null;
    old?.removeListener(_videoTick);
    await old?.dispose();
  }

  void _videoTick() {
    final player = _video;
    if (_disposed || player == null || !state.isCircle) return;
    final value = player.value;
    if (value.isCompleted || value.hasError) {
      state = VoicePlayback(speed: state.speed);
      unawaited(_releaseVideo());
      return;
    }
    if (state.position != value.position ||
        state.duration != value.duration ||
        state.playing != value.isPlaying) {
      state = state.copyWith(
        position: value.position,
        duration: value.duration,
        playing: value.isPlaying,
      );
    }
  }

  Future<void> toggleCircle({
    required String messageId,
    required String path,
    required String chatId,
    required String chatTitle,
    DateTime? sentAt,
  }) async {
    if (!File(path).existsSync()) return;
    if (state.isCurrent(messageId) && _video != null) {
      await togglePlayPause();
      return;
    }
    final generation = ++_generation;
    state = VoicePlayback(
      messageId: messageId,
      chatId: chatId,
      chatTitle: chatTitle,
      sentAt: sentAt,
      speed: state.speed,
      isCircle: true,
    );
    await _player?.stop();
    if (_disposed || generation != _generation) return;
    await _releaseVideo();
    if (_disposed || generation != _generation) return;
    final player = createVideo(path);
    _video = player;
    try {
      await AudioSession.applyPlaybackPolicy();
      if (_disposed || generation != _generation || _video != player) return;
      await player.initialize();
      if (_disposed || generation != _generation || _video != player) return;
      await player.setLooping(false);
      if (_disposed || generation != _generation) return;
      await player.setPlaybackSpeed(state.speed);
      if (_disposed || generation != _generation) return;
      player.addListener(_videoTick);
      await player.play();
      if (_disposed || generation != _generation) return;
      ref
          .read(messagesControllerProvider.notifier)
          .markVoicePlayed(chatId, messageId);
      _videoTick();
    } catch (_) {
      if (!_disposed && generation == _generation) {
        state = VoicePlayback(speed: state.speed);
        await _releaseVideo();
      }
    }
  }

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _doneSub;

  /// Speeds the pill cycles through. Anything below 1 is a novelty on speech
  /// and anything above 2 is unintelligible.
  static const speeds = <double>[1.0, 1.5, 2.0];

  @override
  VoicePlayback build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_releaseVideo());
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

    // Before the first player exists, so the session it creates is the mixing
    // one. A `playback` session without mixWithOthers stops whatever else the
    // phone was playing — see [AudioSession.playback].
    unawaited(AudioSession.applyPlaybackPolicy());
    final player = AudioPlayer();
    _posSub = player.onPositionChanged.listen((d) {
      if (!state.isCircle && state.isActive) {
        state = state.copyWith(position: d);
      }
    });
    _durSub = player.onDurationChanged.listen((d) {
      if (!state.isCircle && state.isActive && d > Duration.zero) {
        state = state.copyWith(duration: d);
      }
    });
    _doneSub = player.onPlayerComplete.listen((_) {
      if (state.isCircle) return;
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
    DateTime? sentAt,
    Duration? knownDuration,
  }) async {
    if (!File(path).existsSync()) return;
    final generation = ++_generation;
    await _releaseVideo();
    if (_disposed || generation != _generation) return;
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

    // Heard, from this moment on. Recorded when playback *starts* rather than
    // when it finishes: the dot answers "have I opened this", and a note
    // someone listened to half of is not new to them any more.
    ref.read(messagesControllerProvider.notifier).markVoicePlayed(
          chatId,
          messageId,
        );

    // A different message: replace rather than layer.
    await player.stop();
    if (_disposed || generation != _generation) return;
    state = VoicePlayback(
      messageId: messageId,
      chatId: chatId,
      chatTitle: chatTitle,
      sentAt: sentAt,
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
    final video = _video;
    if (state.isCircle && video != null) {
      if (!video.value.isInitialized) return;
      if (video.value.isPlaying) {
        await video.pause();
      } else {
        await video.play();
      }
      return;
    }
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
    if (state.isCircle) {
      await _video?.seekTo(position);
    } else {
      await _player?.seek(position);
    }
    state = state.copyWith(position: position);
  }

  Future<void> seekFraction(double fraction) => seekTo(
        Duration(
          milliseconds:
              (state.duration.inMilliseconds * fraction.clamp(0.0, 1.0))
                  .round(),
        ),
      );

  Future<void> cycleSpeed() async {
    final next = speeds[(speeds.indexOf(state.speed) + 1) % speeds.length];
    state = state.copyWith(speed: next);
    if (state.isCircle) {
      await _video?.setPlaybackSpeed(next);
    } else {
      await _player?.setPlaybackRate(next);
    }
  }

  /// Dismiss the bar entirely.
  Future<void> stop() async {
    _generation++;
    state = VoicePlayback(speed: state.speed);
    await _releaseVideo();
    await _player?.stop();
  }
}

final voicePlaybackControllerProvider =
    NotifierProvider<VoicePlaybackController, VoicePlayback>(
  VoicePlaybackController.new,
);
