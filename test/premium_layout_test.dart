import 'dart:io';
import 'dart:ui' as ui;

import 'package:cubechat/core/theme/app_theme.dart';
import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/peers/presentation/peers_screen.dart';
import 'package:cubechat/features/peers/data/peer_discovery_controller.dart';
import 'package:cubechat/features/peers/data/peripheral_controller.dart';
import 'package:cubechat/features/peers/models/discovered_peer.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

class _Nearby extends PeerDiscoveryController {
  @override
  PeerDiscoveryState build() => PeerDiscoveryState(
        status: PeerDiscoveryStatus.scanning,
        peers: [
          DiscoveredPeer(
            id: '0a:21:57:af',
            advertisedName: 'Марія',
            rssi: -55,
            lastSeen: DateTime.now(),
          ),
        ],
      );
  @override
  Future<void> start() async {}
  @override
  Future<void> retuneScan() async {}
}

class _Peripheral extends PeripheralController {
  @override
  PeripheralState build() => const PeripheralState(
        status: PeripheralStatus.broadcasting,
        connectedCentralIds: {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  setUpAll(() async {
    // Actual Latin/Cyrillic glyph widths, not the test VM's square Ahem font.
    final inter = FontLoader('Inter');
    for (final weight in [
      'Regular',
      'Medium',
      'SemiBold',
      'Bold',
      'ExtraBold',
    ]) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$weight.ttf'));
    }
    await inter.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final display = FontLoader('SpaceGrotesk')
      ..addFont(rootBundle.load('.codex/fonts/SpaceGrotesk-SemiBold.ttf'))
      ..addFont(rootBundle.load('.codex/fonts/SpaceGrotesk-Bold.ttf'));
    final mono = FontLoader('JetBrainsMono')
      ..addFont(rootBundle.load('.codex/fonts/JetBrainsMono-Medium.ttf'));
    await display.load();
    await mono.load();
  });
  setUp(() async {
    storage = await Directory.systemTemp.createTemp('cubechat_premium_');
    Hive.init(storage.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
  });

  final now = DateTime.now();
  final chats = [
    for (final (index, name, message) in [
      (0, 'Олександра', 'Побачимось о сьомій біля кав’ярні?'),
      (1, 'Максим Коваленко', 'Відеоповідомлення'),
      (2, 'Дизайн та натхнення', 'Зібрали нову добірку для вас'),
      (3, 'Anastasiia Shevchenko', 'Дякую, усе отримала!'),
      (4, 'Богдан', 'Я вже поруч'),
    ])
      Chat(
        id: 'premium-$index',
        peerId: 'premium-$index',
        peerName: name,
        lastMessage: message,
        lastTime: now.subtract(Duration(minutes: index * 8)),
        unreadCount: index < 2 ? 3 : 0,
        isMesh: false,
        isChannel: index == 2,
        isDraft: index == 4,
        isMuted: index == 3,
        isVerified: index == 0,
      ),
  ];

  for (final (label, size, scale) in [
    ('phone', const Size(390, 844), 1.0),
    ('narrow', const Size(320, 740), 1.0),
    ('large-text', const Size(320, 740), 1.3),
    ('tablet', const Size(768, 1024), 1.0),
  ]) {
    for (final (screenName, screen) in <(String, Widget)>[
      ('chats', const ChatsListScreen()),
      ('contacts', const ContactsScreen()),
      ('nearby', const PeersScreen()),
      ('profile', ProfileScreen()),
    ]) {
      testWidgets('$screenName fits $label with bundled fonts', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              chatsProvider.overrideWithValue(chats),
              peerDiscoveryControllerProvider.overrideWith(_Nearby.new),
              peripheralControllerProvider.overrideWith(_Peripheral.new),
            ],
            child: MaterialApp(
              theme: AppTheme.dark(),
              locale: const Locale('uk'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(scale),
                ),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.bgTop, AppColors.bgBottom],
                    ),
                  ),
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    body: screen,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        Future<void> capture(String suffix) async {
          if (!const bool.fromEnvironment('PREMIUM_CAPTURE')) return;
          await tester.runAsync(() async {
            final render = boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final dir = Directory('design-previews/premium-mvp')
              ..createSync(recursive: true);
            File('${dir.path}/$screenName-$label$suffix.png')
                .writeAsBytesSync(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('');
        if (screenName == 'profile') {
          await tester.ensureVisible(find.byIcon(Icons.radar_rounded).first);
          await tester.tap(find.byIcon(Icons.radar_rounded).first);
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
          await capture('-expanded');
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
