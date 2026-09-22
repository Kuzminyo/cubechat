import 'dart:async';
import 'dart:io';

import 'package:cubechat/features/files/data/file_transfer_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_transfers_test_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive file handle after close.
    }
  });

  FileTransferTask task({
    String id = 'transfer-1',
    FileTransferStatus status = FileTransferStatus.queued,
  }) {
    final now = DateTime(2026, 8, 3, 12);
    return FileTransferTask(
      id: id,
      chatId: 'alice',
      fileName: 'photo.jpg',
      messageId: 'message-1',
      filePath: 'C:/tmp/photo.jpg',
      mime: 'image/jpeg',
      bytesTotal: 2048,
      completedUnits: 0,
      totalUnits: 4,
      direction: FileTransferDirection.outgoing,
      status: status,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('tracks progress and completion', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task());

    controller.setProgress('transfer-1', 2, 4);
    expect(
      container.read(fileTransferControllerProvider)['transfer-1']?.progress,
      0.5,
    );

    controller.complete('transfer-1');
    expect(
      container.read(fileTransferControllerProvider)['transfer-1']?.status,
      FileTransferStatus.completed,
    );
  });

  test('pause blocks a sender until resume', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task(status: FileTransferStatus.transferring));
    controller.pause('transfer-1');

    var released = false;
    final waiting = controller.waitUntilRunnable('transfer-1').then((value) {
      released = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(released, isFalse);

    controller.resume('transfer-1');
    expect(await waiting, isTrue);
  });

  test('cancel releases a paused sender and reports cancellation', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task(status: FileTransferStatus.transferring));
    controller.pause('transfer-1');

    final waiting = controller.waitUntilRunnable('transfer-1');
    controller.cancel('transfer-1');
    expect(await waiting, isFalse);
    expect(
      container.read(fileTransferControllerProvider)['transfer-1']?.status,
      FileTransferStatus.canceled,
    );
  });

  // The send loop reports a chunk after it has gone out, so the report of the
  // chunk in flight lands right after the tap. It used to write
  // "transferring" over the pause and the cancel both, and the loop went on.
  test('a chunk reported after a pause leaves the transfer paused', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task(status: FileTransferStatus.transferring));
    controller.pause('transfer-1');

    controller.setProgress('transfer-1', 3, 4);

    final value = container.read(fileTransferControllerProvider)['transfer-1'];
    expect(value?.status, FileTransferStatus.paused);
    expect(value?.completedUnits, 3);
    var released = false;
    unawaited(
      controller.waitUntilRunnable('transfer-1').then((_) => released = true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(released, isFalse);
    controller.resume('transfer-1');
  });

  test('a chunk reported after a cancel leaves the transfer cancelled',
      () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task(status: FileTransferStatus.transferring));
    controller.cancel('transfer-1');

    controller.setProgress('transfer-1', 4, 4);

    expect(
      container.read(fileTransferControllerProvider)['transfer-1']?.status,
      FileTransferStatus.canceled,
    );
    expect(await controller.waitUntilRunnable('transfer-1'), isFalse);
  });

  test('queue survives restart and keeps message identity', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task(status: FileTransferStatus.paused));
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    final restored = relaunched.read(fileTransferControllerProvider.notifier);
    await restored.loaded;
    final value = relaunched.read(fileTransferControllerProvider)['transfer-1'];

    expect(value?.status, FileTransferStatus.queued);
    expect(value?.messageId, 'message-1');
  });

  test('an AirDrop task keeps its source and sender name across a restart',
      () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(
      FileTransferTask(
        id: 'air-1',
        chatId: 'bob',
        fileName: 'clip.mp4',
        filePath: 'C:/tmp/clip.mp4',
        mime: 'video/mp4',
        bytesTotal: 10,
        completedUnits: 10,
        totalUnits: 10,
        direction: FileTransferDirection.incoming,
        status: FileTransferStatus.completed,
        createdAt: DateTime(2026, 9, 22),
        updatedAt: DateTime(2026, 9, 22),
        source: FileTransferSource.airdrop,
        peerName: 'Жека',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    final restored = relaunched.read(fileTransferControllerProvider.notifier);
    await restored.loaded;
    final value = relaunched.read(fileTransferControllerProvider)['air-1'];
    expect(value?.source, FileTransferSource.airdrop);
    expect(value?.peerName, 'Жека');
  });

  // The file queue retries queued outgoing tasks as chat sends. An AirDrop
  // needs the person in reach and their yes, so after a restart it is failed —
  // the AirDrop page offers "retry" — and never quietly re-sent into a chat.
  test('an outgoing AirDrop is failed after a restart, not queued', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(
      FileTransferTask(
        id: 'air-2',
        chatId: 'bob',
        fileName: 'a.jpg',
        filePath: 'C:/tmp/a.jpg',
        mime: 'image/jpeg',
        bytesTotal: 10,
        completedUnits: 1,
        totalUnits: 4,
        direction: FileTransferDirection.outgoing,
        status: FileTransferStatus.transferring,
        createdAt: DateTime(2026, 9, 22),
        updatedAt: DateTime(2026, 9, 22),
        source: FileTransferSource.airdrop,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(fileTransferControllerProvider.notifier).loaded;
    expect(
      relaunched.read(fileTransferControllerProvider)['air-2']?.status,
      FileTransferStatus.failed,
    );
  });

  test('a record written before sources existed reads as a chat file',
      () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task(status: FileTransferStatus.completed));
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final relaunched = ProviderContainer();
    addTearDown(relaunched.dispose);
    await relaunched.read(fileTransferControllerProvider.notifier).loaded;
    expect(
      relaunched.read(fileTransferControllerProvider)['transfer-1']?.source,
      FileTransferSource.chat,
    );
  });

  test('clearFinished retains only active transfers', () async {
    final controller = container.read(fileTransferControllerProvider.notifier);
    await controller.loaded;
    controller.register(task());
    controller.register(
      task(id: 'done', status: FileTransferStatus.completed),
    );

    await controller.clearFinished();
    expect(container.read(fileTransferControllerProvider).keys, ['transfer-1']);
  });
}
