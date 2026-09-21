import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Which language a voice note is heard in when it is turned into text.
///
/// The recogniser is on the device and needs to be told a language; it cannot
/// guess. Until this existed it was told the app's own, which on a phone set
/// to Ukrainian meant "uk" for every note — and the notes in the reports were
/// spoken in Russian, on a phone with no Ukrainian model, so every one failed
/// with error 12 ("не може розпізнати"). The language people write the app in
/// and the one they speak are not the same question.
enum TranscriptionLanguage {
  /// The phone's own languages, in its order, then the app's.
  auto(null),
  russian('ru-RU'),
  ukrainian('uk-UA'),
  english('en-US');

  const TranscriptionLanguage(this.tag);

  /// BCP 47 tag for the recogniser, or null for [auto].
  final String? tag;
}

/// The languages to offer the recogniser, most wanted first.
///
/// A chosen language is the only one: falling back from Russian to a
/// Ukrainian model would print confident nonsense, which is worse than
/// saying the model is missing. [auto] offers the phone's languages and then
/// [appLocale], deduplicated, and the platform uses the first it has a model
/// for.
List<String> transcriptionCandidates(
  TranscriptionLanguage choice, {
  String? appLocale,
  List<String>? systemLocales,
}) {
  final chosen = choice.tag;
  if (chosen != null) return [chosen];
  final out = <String>[];
  for (final tag in [
    ...systemLocales ??
        PlatformDispatcher.instance.locales.map((l) => l.toLanguageTag()),
    if (appLocale != null) appLocale,
  ]) {
    if (tag.isEmpty || tag == 'und') continue;
    if (!out.contains(tag)) out.add(tag);
  }
  return out;
}

class TranscriptionLanguageController extends Notifier<TranscriptionLanguage> {
  static const _key = 'transcribe.language';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  Future<TranscriptionLanguage> resolved() async {
    await loaded;
    return state;
  }

  @override
  TranscriptionLanguage build() {
    unawaited(_loading = _load());
    return TranscriptionLanguage.auto;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final name = box.get(_key) as String?;
      state = TranscriptionLanguage.values
              .where((l) => l.name == name)
              .firstOrNull ??
          TranscriptionLanguage.auto;
    } catch (e) {
      debugPrint('Transcription language load failed: $e');
    }
  }

  Future<void> set(TranscriptionLanguage language) async {
    state = language;
    await loaded;
    state = language;
    try {
      await _box?.put(_key, language.name);
    } catch (e) {
      debugPrint('Transcription language persist failed: $e');
    }
  }

  /// Emergency Wipe: back to what a fresh install has.
  Future<void> reset() async {
    await loaded;
    state = TranscriptionLanguage.auto;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Transcription language reset failed: $e');
    }
  }
}

final transcriptionLanguageProvider =
    NotifierProvider<TranscriptionLanguageController, TranscriptionLanguage>(
  TranscriptionLanguageController.new,
);
