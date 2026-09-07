// How many offscreen passes the GPU is asked for, per screen.
//
// The frame numbers on a real phone say the raster thread is where the cost is
// — 33% of a core against 16% for everything Dart does — and the perf notes say
// the next thing worth looking at is overdraw, which nobody had counted. This
// counts it.
//
// What is counted is layers that force a `saveLayer`: a backdrop filter, an
// opacity group, a colour or image filter, a shader mask. Each one is a
// separate render target the GPU fills and then composites, and each is paid
// for on every frame the content under it moves. Plain painting is not counted
// and does not need to be — it is the offscreen passes that turn a 1 ms frame
// into a 6 ms one.
//
// The numbers below are what the screens cost today, written down so a change
// that doubles them is visible in a diff instead of in somebody's battery.
import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/peers/presentation/peers_screen.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// Layer types that make the GPU render into a texture of its own.
const _offscreen = <String>{
  'BackdropFilterLayer',
  'OpacityLayer',
  'ColorFilterLayer',
  'ImageFilterLayer',
  'ShaderMaskLayer',
};

Map<String, int> _census(Layer? layer, [Map<String, int>? into]) {
  final counts = into ?? <String, int>{};
  for (var node = layer; node != null; node = node.nextSibling) {
    final name = node.runtimeType.toString();
    if (_offscreen.contains(name)) {
      counts[name] = (counts[name] ?? 0) + 1;
    }
    if (node is ContainerLayer) _census(node.firstChild, counts);
  }
  return counts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_layers_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  /// Render [screen] on a phone-shaped surface and count its offscreen passes.
  Future<int> offscreenPasses(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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
    // Settled, not pumped once: an entrance still running is an opacity layer
    // that will not be there a moment later, and counting it would make the
    // number depend on when the frame was taken.
    await tester.pump(const Duration(seconds: 1));

    final counts = _census(tester.binding.renderViews.first.debugLayer);
    final total = counts.values.fold(0, (a, b) => a + b);
    // Printed as well as asserted: a failure should say what grew, not only
    // that something did.
    // ignore: avoid_print
    print('offscreen passes: $total  $counts');
    return total;
  }

  testWidgets('the chats list', (tester) async {
    expect(await offscreenPasses(tester, const ChatsListScreen()),
        lessThanOrEqualTo(8));
  });

  testWidgets('the contacts screen', (tester) async {
    expect(await offscreenPasses(tester, const ContactsScreen()),
        lessThanOrEqualTo(8));
  });

  testWidgets('the peers screen', (tester) async {
    expect(
        await offscreenPasses(tester, const PeersScreen()), lessThanOrEqualTo(8));
  });

  testWidgets('the profile screen', (tester) async {
    expect(await offscreenPasses(tester, ProfileScreen()),
        lessThanOrEqualTo(12));
  });

  // The screens above turn out to carry no blur at all — the census finds only
  // opacity groups on them. So the gaussian, which is the expensive kind of
  // offscreen pass, lives entirely in the chat: its header, its pinned bar and
  // its composer are the same widget, and each one is a pass of its own.
  //
  // Counted here rather than by rendering the chat screen, which needs a peer,
  // a session and a conversation to exist before it will build. One island is
  // the unit; the chat shows at most three of them.
  testWidgets('one chat island is one blur, and only one', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 120));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<Map<String, int>> census(Widget island) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ColoredBox(
            color: const Color(0xFF06140D),
            child: Center(
              child: SizedBox(width: 340, height: 56, child: island),
            ),
          ),
        ),
      );
      await tester.pump();
      return _census(tester.binding.renderViews.first.debugLayer);
    }

    // The scaffolding around it first. `MaterialApp` composes layers of its
    // own, and counting those as the island's would make the island look four
    // times more expensive than it is.
    final bare = await census(const SizedBox.expand());
    final withIsland =
        await census(const MessageIslandGlass(child: SizedBox.expand()));

    final added = <String, int>{
      for (final key in {...bare.keys, ...withIsland.keys})
        if ((withIsland[key] ?? 0) - (bare[key] ?? 0) != 0)
          key: (withIsland[key] ?? 0) - (bare[key] ?? 0),
    };
    // ignore: avoid_print
    print('one island adds: $added  (scaffolding alone: $bare)');

    expect(
      added,
      {'BackdropFilterLayer': 1},
      reason: 'an island should cost one gaussian and nothing else. It is on '
          'screen three times over in a conversation, and every one of these '
          'is paid again on every frame the messages move behind it',
    );
  });
}
