import 'dart:convert';
import 'dart:io';

import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/moderation/domain/profanity.dart';
import 'package:flutter_test/flutter_test.dart';

Message message(String text, {bool mine = false}) => Message(
      id: 'one',
      chatId: '#room',
      text: text,
      sentAt: DateTime(2026),
      isMine: mine,
    );

void main() {
  test('common obfuscations normalize to the same word', () {
    expect(normaliseForFilter('х у й'), contains('хуй'));
    expect(normaliseForFilter('хyй'), contains('хуй'));
    expect(normaliseForFilter('fuuuck'), contains('fuck'));
    expect(normaliseForFilter('f*ck'), contains('fuck'));
    expect(containsProfanity('б.л.я'), isTrue);
    expect(containsProfanity('FUUUCK'), isTrue);
  });

  test('allow-list words are not censored', () {
    for (final word in [
      'скипидар',
      'потребля',
      'оскорбля',
      'страхуй',
      'document',
      'scunthorpe',
      'assess',
      'cocktail',
      'shitake',
    ]) {
      expect(containsProfanity(word), isFalse, reason: word);
    }
  });

  // Ordinary words that *start* with a stem, which is the only way the
  // prefix match can misfire. "сукня" and "сукупність" folded under the
  // handoff's bare 'сук' stem.
  test('everyday words that begin like a stem are not folded', () {
    for (final text in [
      'Яка гарна сукня!',
      'сукупність умов',
      'сукно',
      'сучасний',
      'купив бляшанку фарби',
      'бляха',
      'вакцина від Еболи',
      'a minor niggle',
      'fire retardant',
      'shiitake mushrooms',
      'Скипидару вистачить',
      'страхування',
      'команда',
    ]) {
      expect(containsProfanity(text), isFalse, reason: text);
    }
  });

  test('the forms that replaced the bare stem still fold', () {
    for (final text in ['ти сука', 'суки', 'сучара', 'хyй з Latin y', 'f*ck']) {
      expect(containsProfanity(text), isTrue, reason: text);
    }
  });

  // A corpus of ordinary en/uk sentences already in the tree: every string
  // the app itself shows. None of them is rude, so none may fold.
  test('no string the app itself shows would be folded', () {
    for (final file in ['lib/l10n/app_en.arb', 'lib/l10n/app_uk.arb']) {
      final arb = jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
      for (final entry in arb.entries) {
        if (entry.key.startsWith('@')) continue;
        final value = entry.value;
        if (value is! String) continue;
        expect(containsProfanity(value), isFalse, reason: '${entry.key}: $value');
      }
    }
  });

  test('a stranger is somebody you have not written to', () {
    expect(hasWrittenIn(null), isFalse);
    expect(hasWrittenIn([message('hi')]), isFalse);
    expect(hasWrittenIn([message('hi'), message('hey', mine: true)]), isTrue);
  });

  test('filter only folds incoming text from strangers or channels', () {
    final rude = message('shit');
    expect(
      shouldFilter(
          message: rude, isChannel: false, fromContact: false, enabled: true),
      isTrue,
    );
    expect(
      shouldFilter(
          message: rude, isChannel: true, fromContact: true, enabled: true),
      isTrue,
    );
    expect(
      shouldFilter(
          message: rude, isChannel: false, fromContact: true, enabled: true),
      isFalse,
    );
    expect(
      shouldFilter(
          message: rude, isChannel: true, fromContact: true, enabled: false),
      isFalse,
    );
    expect(
      shouldFilter(
          message: message('shit', mine: true),
          isChannel: true,
          fromContact: false,
          enabled: true),
      isFalse,
    );
  });
}
