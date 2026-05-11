import 'package:cubechat/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('CubechatApp boots and shows the chats screen title',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    // Pump a few frames to settle animations and async restore work.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200));

    // English locale is the default — "Chats" should appear as the page title.
    expect(find.text('Chats'), findsWidgets);
  });
}
