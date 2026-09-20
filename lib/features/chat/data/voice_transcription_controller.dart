import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  final Set<String> _running = <String>{};

  @override
  Map<String, String> build() => const <String, String>{};

  bool isRunning(String messageId) => _running.contains(messageId);

  /// Transcribe [audioPath] and remember the result under [messageId].
  ///
  /// Returns the text, or null when the platform could not produce one. A
  /// message already transcribed is answered from memory: the work costs
  /// seconds and a wakeful CPU, and the answer cannot change.
  Future<String?> transcribe({
    required String messageId,
    required String audioPath,
    String? localeId,
  }) async {
    final cached = state[messageId];
    if (cached != null) return cached;
    if (!_running.add(messageId)) return null;
    try {
      final text = await channel.invokeMethod<String>('transcribe', {
        'path': audioPath,
        if (localeId != null) 'locale': localeId,
      });
      final trimmed = text?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      state = {...state, messageId: trimmed};
      return trimmed;
    } on PlatformException catch (e) {
      debugPrint('transcribe failed: ${e.code} ${e.message}');
      return null;
    } on MissingPluginException {
      // A desktop or web build, where there is no recogniser at all.
      return null;
    } finally {
      _running.remove(messageId);
    }
  }

  /// Drop a transcript — used when its message is deleted.
  void forget(String messageId) {
    if (!state.containsKey(messageId)) return;
    final next = {...state}..remove(messageId);
    state = next;
  }
}

final voiceTranscriptionProvider =
    NotifierProvider<VoiceTranscriptionController, Map<String, String>>(
  VoiceTranscriptionController.new,
);
