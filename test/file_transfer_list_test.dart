import 'dart:io';

import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:cubechat/features/files/presentation/file_transfer_center_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Tasks extends FileTransferController {
  _Tasks(this.tasks);

  final Map<String, FileTransferTask> tasks;

  @override
  Map<String, FileTransferTask> build() => tasks;
}

FileTransferTask _task(
  String id, {
  required FileTransferDirection direction,
  required FileTransferStatus status,
  String path = '',
}) =>
    FileTransferTask(
      id: id,
      chatId: 'bb' * 32,
      fileName: '$id.jpg',
      filePath: path,
      mime: 'image/jpeg',
      bytesTotal: 10,
      completedUnits: 1,
      totalUnits: 1,
      direction: direction,
      status: status,
      createdAt: DateTime(2026, 9, 22),
      updatedAt: DateTime(2026, 9, 22),
      source: FileTransferSource.airdrop,
      peerName: 'Жека',
    );

void main() {
  testWidgets('an AirDrop file says so, and is never offered a chat retry',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('cubechat_files_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final kept = File('${dir.path}${Platform.pathSeparator}in.jpg')
      ..writeAsStringSync('x');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileTransferControllerProvider.overrideWith(
            () => _Tasks({
              'in': _task(
                'in',
                direction: FileTransferDirection.incoming,
                status: FileTransferStatus.completed,
                path: kept.path,
              ),
              'out': _task(
                'out',
                direction: FileTransferDirection.outgoing,
                status: FileTransferStatus.failed,
              ),
            }),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('uk'),
          home: Scaffold(body: FileTransferList()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AirDrop · Жека'), findsNWidgets(2));
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);

    await tester.longPress(find.text('in.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('AirDrop'), findsOneWidget);
    expect(find.text('Видалити'), findsOneWidget);
  });
}
