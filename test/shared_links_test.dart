import 'package:cubechat/features/peers/presentation/contact_content_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Links tab finds URLs in ordinary text — links are not a message kind,
/// so there is nothing to filter on and everything to get wrong.
void main() {
  test('an explicit link is found and its sentence is not', () {
    expect(
      linksIn('лови https://goodboysclub.net.ua/collections/odyag, там знижки'),
      ['https://goodboysclub.net.ua/collections/odyag'],
    );
    expect(
      linksIn('(див. www.example.com/page)'),
      ['www.example.com/page'],
    );
  });

  test('several links keep the order they were written in', () {
    expect(
      linksIn('http://one.example/a then https://two.example/b'),
      ['http://one.example/a', 'https://two.example/b'],
    );
  });

  test('nothing in ordinary text is promoted to a link', () {
    // A bare domain, a version number and a file size all look enough like one
    // to a loose matcher — and a Links tab full of "3.5mb" is worse than an
    // empty one, because it is a list you scan rather than read.
    expect(linksIn('розмір 3.5mb, версія 1.2.3'), isEmpty);
    expect(linksIn('пиши на example.com'), isEmpty);
    expect(linksIn('нічого тут немає'), isEmpty);
  });
}
