import 'package:cubechat/core/transport/contact_card.dart';
import 'package:cubechat/features/cube_id/domain/cubechat_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a shared @name link opens that name', () {
    final link =
        parseCubechatLink(Uri.parse('https://cubechat.tech/u.html#Dima'));
    expect(link, isA<NameLink>());
    expect((link! as NameLink).name, 'dima');
    expect(
      parseCubechatLink(Uri.parse('https://cubechat.tech/u.html#%40dima_2')),
      isA<NameLink>(),
    );
  });

  test('a card link carries the whole card text', () {
    final card = 'cubechat:c1:${'A' * 300}';
    final link = parseCubechatLink(Uri.parse('https://cubechat.tech/c1#$card'));
    expect(link, isA<CardLink>());
    expect((link! as CardLink).raw, contains(card));
  });

  test('the card link we hand out is one we can open', () {
    expect(ContactCard.linkPrefix, startsWith('https://cubechat.tech/c1#'));
  });

  test('anything else is not ours', () {
    expect(parseCubechatLink(Uri.parse('https://cubechat.tech/')), isNull);
    expect(
        parseCubechatLink(Uri.parse('https://cubechat.tech/u.html')), isNull);
    expect(parseCubechatLink(Uri.parse('https://cubechat.tech/u.html#ab')),
        isNull);
    expect(parseCubechatLink(Uri.parse('https://evil.example/u.html#dima')),
        isNull);
    expect(
        parseCubechatLink(Uri.parse('https://cubechat.tech/c1#hello')), isNull);
  });
}
