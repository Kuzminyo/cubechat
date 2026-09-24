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
