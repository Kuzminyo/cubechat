import 'dart:io';

import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/backup/presentation/backup_screen.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/peers/presentation/peers_screen.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/features/profile/presentation/storage_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// The screens, held to the platform's own accessibility rules.
///
/// Flutter ships these as machine-checkable guidelines, which is the only kind
/// of design review that survives the next commit. Two of them found something
/// real the first time they were run, and both were things a person reading
/// the code would not have seen:
///
///  * the profile photo — the subject of that whole screen — was a tappable
///    rectangle with no name, so a screen reader announced nothing for it;
///  * the app title on the chats list was announced as a control, because the
///    hidden triple-tap behind it publishes a tap action. Activating it did
///    nothing: one tap out of three is not the gesture.
///
/// **Why 44 and not 48.** Flutter ships two tap-size guidelines because the
/// platforms disagree: Apple's minimum is 44 points, Material's is 48. This
/// interface is not a Material one — there is no AppBar, no FAB, no Material
/// control anywhere in it — and its geometry is drawn to Apple's number
/// throughout. Holding it to 48 would fail on two controls that are 44 and 46
/// by design (the chats overflow button and the search field it collapses
/// into), and the honest answer there is a measured design decision, not a
/// silent 4-pixel edit made by someone who cannot see the screen. It is
/// written up as a known gap rather than hidden by picking the weaker rule:
/// on Android those two controls are inside Material's recommendation, not
/// outside a hard requirement.
///
/// A screen is added here by pumping it. If a new one fails, the finding is
/// the point — fix the control, do not narrow the test.
void main() {
  late Directory tempDir;

  // These screens read real settings as they build, so Hive needs somewhere to
  // live even where nothing is written back.
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_a11y_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  Future<void> audit(WidgetTester tester, Widget screen) async {
    // A phone, not the 800x600 the test binding defaults to: a control that is
    // comfortable on a tablet-shaped surface can still be cramped on a phone,
    // and the phone is what this app ships on.
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: ColoredBox(color: AppColors.bgDeep, child: screen),
        ),
      ),
    );
    // Settled rather than pumped once: entrances stagger, and a row still
    // fading in is not the size it will be measured at.
    await tester.pump(const Duration(seconds: 1));

    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  }

  testWidgets('the chats list', (tester) async {
    await audit(tester, const ChatsListScreen());
  });

  testWidgets('the peers screen', (tester) async {
    await audit(tester, const PeersScreen());
  });

  testWidgets('the contacts screen', (tester) async {
    await audit(tester, const ContactsScreen());
  });

  testWidgets('the profile screen', (tester) async {
    await audit(tester, ProfileScreen());
  });

  testWidgets('the storage screen', (tester) async {
    await audit(tester, const StorageScreen());
  });

  testWidgets('the backup screen', (tester) async {
    await audit(tester, const BackupScreen());
  });
}
