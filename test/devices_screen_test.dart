import 'dart:async';
import 'dart:typed_data';

import 'package:cubechat/core/transport/own_device_notice.dart';
import 'package:cubechat/features/devices/data/device_identity.dart';
import 'package:cubechat/features/devices/data/own_devices.dart';
import 'package:cubechat/features/devices/data/own_devices_controller.dart';
import 'package:cubechat/features/devices/presentation/devices_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:cubechat/l10n/app_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store implements DeviceIdentityStore {
  @override
  Future<Uint8List> id() async => Uint8List(16);
  @override
  Future<String?> name() async => null;
  @override
  Future<void> setName(String name) async {}
  @override
  Future<void> wipe() async {}
}

/// The Devices page in Profile → Data (2026-10-12).
void main() {
  final t = AppLocalizationsEn();
  final now = DateTime.utc(2026, 10, 12, 12);

  Future<List<OwnDeviceNotice>> pump(
    WidgetTester tester,
    List<OwnDevice> others,
  ) async {
    final sent = <OwnDeviceNotice>[];
    final service = OwnDevicesService(
      send: (n) async => sent.add(n),
      inbound: const Stream.empty(),
      store: _Store(),
      load: () async => others,
      save: (_) async {},
      platform: DevicePlatform.windows,
      defaultName: 'Windows · DESK',
      now: () => now,
    );
    await tester.runAsync(service.start);
    sent.clear();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [ownDevicesProvider.overrideWith((_) => service)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DevicesScreen(now: () => now),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return sent;
  }

  OwnDevice device(String hexByte, String name, DevicePlatform p, Duration ago) =>
      OwnDevice(
        idHex: hexByte * 16,
        name: name,
        platform: p,
        lastSeen: now.subtract(ago),
      );

  testWidgets('this device on top, the others with when they were online',
      (tester) async {
    await pump(tester, [
      device('aa', 'Pixel 8', DevicePlatform.android, const Duration(minutes: 5)),
      device('bb', 'Laptop', DevicePlatform.windows, const Duration(days: 3)),
    ]);
    expect(find.text('Windows · DESK'), findsOneWidget);
    expect(find.text(t.devicesThisDevice), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text(t.devicesSeenMinutes(5)), findsOneWidget);
    expect(find.text(t.devicesSeenDays(3)), findsOneWidget);
    expect(find.text(t.devicesSignOutAll), findsOneWidget);
    expect(find.text(t.devicesCaveat), findsOneWidget);
  });

  testWidgets('signing a phone out warns that it is a phone, then sends it',
      (tester) async {
    final sent = await pump(tester, [
      device('aa', 'Pixel 8', DevicePlatform.android, const Duration(minutes: 5)),
    ]);
    await tester.tap(find.text(t.devicesSignOut));
    await tester.pumpAndSettle();
    expect(find.text(t.devicesSignOutPhoneMessage), findsOneWidget);
    await tester.tap(find.text(t.devicesSignOut).last);
    await tester.pumpAndSettle();
    expect(sent.single.kind, OwnDeviceKind.signOut);
    expect(deviceIdHex(sent.single.targetId!), 'aa' * 16);
    expect(find.text(t.devicesLeaving), findsOneWidget);
  });

  testWidgets('with nobody else yet, it says how a device gets here',
      (tester) async {
    await pump(tester, const []);
    expect(find.text(t.devicesEmpty), findsOneWidget);
    expect(find.text(t.devicesSignOutAll), findsNothing);
  });
}
