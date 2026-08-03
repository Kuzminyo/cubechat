import 'package:cubechat/features/peers/presentation/contact_content_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('content item route points at the exact message in its chat', () {
    final route = Uri.parse(
      routeForMessageInChat(
        chatId: 'peer/one',
        contactName: 'Alice & Bob',
        messageId: 'm-42',
      ),
    );

    expect(route.pathSegments, ['chat', 'peer/one']);
    expect(route.queryParameters['name'], 'Alice & Bob');
    expect(route.queryParameters['message'], 'm-42');
  });
}
