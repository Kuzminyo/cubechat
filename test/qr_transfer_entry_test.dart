import 'package:cubechat/features/backup/data/desktop_link_service.dart';
import 'package:cubechat/features/backup/data/phone_transfer_socket_service.dart';
import 'package:cubechat/features/qr/presentation/qr_scanner_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';

void main() {
  testWidgets('denied camera permission has retry and settings actions',
      (tester) async {
    const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
    var requests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'requestPermissions') {
        requests++;
        return <int, int>{1: 0};
      }
      return false;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: QrScannerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QRCodeDartScanView), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(tester.takeException(), isNull);
  });
  const phone = PhoneTransferPayload(
    host: '192.168.1.2',
    port: 4000,
    token: '01234567890123456789012345',
    password: '01234567890123456789012345',
  );
  const pc = DesktopLinkPayload(
    host: '192.168.1.3',
    port: 4001,
    token: '01234567890123456789012345',
    password: '01234567890123456789012345',
  );
  test('browser fragments, legacy links and custom scheme handoffs decode', () {
    for (final raw in [
      phone.encode(),
      phone.encode().replaceFirst('cubechat.tech', 'cubechat.app'),
      'cubechat://t1#${Uri.encodeComponent(phone.encode().split('#').last)}',
      'cubechat://t1?c=${Uri.encodeQueryComponent(phone.encode().split('#').last)}',
    ]) {
      expect(isTransferLink(Uri.parse(raw)), isTrue);
      expect(PhoneTransferPayload.tryDecode(raw)?.token, phone.token);
    }
    expect(
      DesktopLinkPayload.tryDecode(
        'cubechat://l1#${Uri.encodeComponent(pc.encode().split('#').last)}',
      )?.token,
      pc.token,
    );
  });
  for (final code in [phone.encode(), pc.encode()]) {
    testWidgets(
        'external ${code.contains('/t1') ? 'transfer' : 'desktop'} link asks for confirmation without opening camera',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: QrScannerScreen(initialCode: code),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(QRCodeDartScanView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
