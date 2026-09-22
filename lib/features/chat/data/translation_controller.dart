import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Turning a message into another language, on the device.
///
/// **The text never reaches a server.** A cloud translator would mean posting
/// the decrypted contents of a private message to somebody else's API, which is
/// the one thing this app exists not to do. ML Kit translates locally.
///
/// One honest caveat, and it is worth saying out loud: the *model* is
/// downloaded from Google the first time a language pair is used. That download
/// says which languages this device wants, and nothing else — no message, no
/// fragment of one, no identity. After it lands, translation is offline
/// forever.
abstract interface class Translator {
  /// The BCP-47 tag of the language [text] is written in, or null when it
  /// cannot be told.
  Future<String?> identify(String text);

  /// Null when the pair is unsupported or the model could not be fetched.
  Future<String?> translate(String text, {required String from, required String to});

  Future<void> dispose();
}

/// The real one. Kept behind [Translator] so the controller can be tested on a
/// machine with no models, no network and no platform — the same seam
/// `EntitlementSource` uses, for the same reason.
class MlKitTranslator implements Translator {
  final _identifier = LanguageIdentifier(confidenceThreshold: 0.5);
  final _models = OnDeviceTranslatorModelManager();

  @override
  Future<String?> identify(String text) async {
    try {
      final tag = await _identifier.identifyLanguage(text);
      // ML Kit says "und" when it will not commit to an answer.
      return tag == 'und' ? null : tag;
    } catch (e) {
      debugPrint('language id failed: $e');
      return null;
    }
  }

  @override
  Future<String?> translate(
    String text, {
    required String from,
    required String to,
  }) async {
    final source = BCP47Code.fromRawValue(from);
    final target = BCP47Code.fromRawValue(to);
    if (source == null || target == null) return null;
    OnDeviceTranslator? translator;
    try {
      // Not Wi-Fi-only. The plugin's default is, and on mobile data that
      // left the download — and the tap that asked for it — waiting for a
      // network that might not come all day. A tap on "translate" is the
      // consent to fetch the language, on whatever connection there is.
      await _models.downloadModel(source.name, isWifiRequired: false);
      await _models.downloadModel(target.name, isWifiRequired: false);
      translator = OnDeviceTranslator(
        sourceLanguage: TranslateLanguage.values.byName(source.name),
        targetLanguage: TranslateLanguage.values.byName(target.name),
      );
      return await translator.translateText(text);
    } catch (e) {
      debugPrint('translate failed: $e');
      return null;
    } finally {
      await translator?.close();
    }
  }

  @override
  Future<void> dispose() async {
    await _identifier.close();
  }
}

final translatorProvider = Provider<Translator>((ref) {
  final translator = MlKitTranslator();
  ref.onDispose(translator.dispose);
  return translator;
});

/// Translations by message id, held in memory.
///
/// Not written to disk: a translation is a way to read one message once, and
/// keeping a second copy of every conversation in another language is a second
/// thing to wipe.
class TranslationController extends Notifier<Map<String, String>> {
  final Set<String> _running = <String>{};

  @override
  Map<String, String> build() => const <String, String>{};

  bool isRunning(String messageId) => _running.contains(messageId);

  /// Translate [text] into [target], remembering it under [messageId].
  ///
  /// Returns null when the language cannot be told, the pair is unsupported,
  /// the model could not be fetched, or the message is already in [target] —
  /// the last of which is a success the interface should not dress up as a
  /// translation.
  Future<String?> translate({
    required String messageId,
    required String text,
    required String target,
  }) async {
    final cached = state[messageId];
    if (cached != null) return cached;
    if (text.trim().isEmpty) return null;
    if (!_running.add(messageId)) return null;
    try {
      final translator = ref.read(translatorProvider);
      final from = await translator.identify(text);
      if (from == null) return null;
      if (from.split('-').first == target.split('-').first) return null;
      final out = await translator.translate(text, from: from, to: target);
      final trimmed = out?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      state = {...state, messageId: trimmed};
      return trimmed;
    } finally {
      _running.remove(messageId);
    }
  }

  void forget(String messageId) {
    if (!state.containsKey(messageId)) return;
    state = {...state}..remove(messageId);
  }
}

final translationProvider =
    NotifierProvider<TranslationController, Map<String, String>>(
  TranslationController.new,
);
