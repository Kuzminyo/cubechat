import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/map/presentation/map_invite_sheet.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('map invitation is presented above the root shell',
      (tester) async {
    final rootNavigator = GlobalKey<NavigatorState>();
    final branchNavigator = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatsProvider.overrideWithValue(const [])],
        child: MaterialApp(
          navigatorKey: rootNavigator,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Navigator(
            key: branchNavigator,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showMapInviteSheet(context),
                    child: const Text('invite'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('invite'));
    await tester.pump();

    expect(rootNavigator.currentState!.canPop(), isTrue);
    expect(branchNavigator.currentState!.canPop(), isFalse);
  });
}
