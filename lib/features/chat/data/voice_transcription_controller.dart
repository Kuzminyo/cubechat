import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/playable_voice.dart';
import '../../../core/util/debug_log.dart';

/// Turning a voice note into text, on the device and nowhere else.
///
/// **No server, and that is not an optimisation.** A cloud transcriber would
/// mean posting the decrypted contents of a private message to somebody else's
/// API — the one thing this app exists not to do. Both platforms can recognise
/// speech locally, so the recording never leaves the phone it is already on.
///
/// Failure is a null, never an exception. A phone whose platform cannot do this
/// — Android below 13, a language with no local model, a device with the
/// recogniser disabled — loses the transcript, not the voice note.
class VoiceTranscriptionController extends Notifier<Map<String, String>> {
  @visibleForTesting
  static const channel = MethodChannel('cubechat/transcribe');

  /// Message ids currently being worked on, so a second tap does not start a
  /// second run over the same file.
  final Map<String, Future<String?>> _running = {};
  final Set<String> _forgotten = {};
  bool _disposed = false;

  @override
  Map<String, String> build() {
    ref.onDispose(() => _disposed = true);
    return const <String, String>{};
  }

  bool isRunning(String messageId) => _running.containsKey(messageId);

  /// Transcribe [audioPath] and remember the result under [messageId].
  ///
  /// Returns the text, or null when the platform could not produce one. A
  /// message already transcribed is answered from memory: the work costs
  /// seconds and a wakeful CPU, and the answer cannot change.
  Future<String?> transcribe({
    required String messageId,
    required String audioPath,
    String? localeId,
  }) {
    final cached = state[messageId];
    if (cached != null) return Future.value(cached);
    return _running[messageId] ??= _transcribe(
      messageId: messageId,
      audioPath: audioPath,
      localeId: localeId,
    ).whenComplete(() {
      _running.remove(messageId);
      _forgotten.remove(messageId);
    });
  }

  Future<String?> _transcribe({
    required String messageId,
    required String audioPath,
    String? localeId,
  }) async {
    try {
      // iOS's recogniser opens no Ogg; an Opus note is transcribed from the
      // WAV it plays as.
      final text = await channel.invokeMethod<String>('transcribe', {
        'path': await PlayableVoice.pathFor(audioPath),
        if (localeId != null) 'locale': localeId,
      });
      final trimmed = text?.trim();
      if (_disposed || _forgotten.contains(messageId)) return null;
      if (trimmed == null || trimmed.isEmpty) {
        DebugLog.instance.log('TRANSCRIBE', 'no local transcript');
        return null;
      }
      state = {...state, messageId: trimmed};
      return trimmed;
    } on PlatformException catch (e) {
      // Error codes only: paths and recognised private speech stay out of logs.
      DebugLog.instance.log('TRANSCRIBE', 'native error ${e.code}');
      return null;
    } on MissingPluginException {
      // A desktop or web build, where there is no recogniser at all.
      return null;
    }
  }

  /// Drop a transcript — used when its message is deleted.
  void forget(String messageId) {
    if (_running.containsKey(messageId)) _forgotten.add(messageId);
    if (!state.containsKey(messageId)) return;
    final next = {...state}..remove(messageId);
    state = next;
  }
}

final voiceTranscriptionProvider =
    NotifierProvider<VoiceTranscriptionController, Map<String, String>>(
  VoiceTranscriptionController.new,
);
