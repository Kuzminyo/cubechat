import 'package:cubechat/features/chat/data/transcription_language.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which languages a voice note is offered to the recogniser in.
///
/// 2026-09-21: every "→A" on one phone failed with Android's error 12,
/// ERROR_LANGUAGE_NOT_SUPPORTED — the app's own language ("uk") was the only
/// one asked for, the phone had no Ukrainian model, and the notes were spoken
/// in Russian anyway.
void main() {
  test('auto offers the phone languages first, then the app language', () {
    expect(
      transcriptionCandidates(
        TranscriptionLanguage.auto,
        appLocale: 'uk',
        systemLocales: const ['ru-RU', 'en-US'],
      ),
      ['ru-RU', 'en-US', 'uk'],
    );
  });

  test('auto does not repeat a language or offer an empty one', () {
    expect(
      transcriptionCandidates(
        TranscriptionLanguage.auto,
        appLocale: 'uk-UA',
        systemLocales: const ['uk-UA', 'und', ''],
      ),
      ['uk-UA'],
    );
  });

  test('a chosen language is the only one asked for', () {
    // Falling back from Russian speech to a Ukrainian model would print
    // confident nonsense; a missing model is said instead.
    expect(
      transcriptionCandidates(
        TranscriptionLanguage.russian,
        appLocale: 'uk',
        systemLocales: const ['uk-UA'],
      ),
      ['ru-RU'],
    );
  });
}
