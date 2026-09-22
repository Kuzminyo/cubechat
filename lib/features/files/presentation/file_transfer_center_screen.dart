import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/media_storage.dart';
import '../../../core/utils/file_mime.dart';
import '../../../core/widgets/context_popup.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../../airdrop/data/airdrop_history_controller.dart';
import '../../airdrop/data/airdrop_source.dart';
import '../../airdrop/presentation/airdrop_send_flow.dart';
import '../data/file_transfer_controller.dart';

class FileTransferCenterScreen extends ConsumerWidget {
  const FileTransferCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final finished = ref.watch(
      fileTransferControllerProvider
          .select((tasks) => tasks.values.any((task) => !task.active)),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          t.fileTransfersTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
        actions: [
          if (finished)
            IconButton(
              tooltip: t.fileTransfersClear,
              onPressed: () => ref
                  .read(fileTransferControllerProvider.notifier)
                  .clearFinished(),
              icon: const Icon(Icons.cleaning_services_rounded),
            ),
        ],
      ),
      body: const FileTransferList(),
    );
  }
}

/// The transfer centre's list — every file this app moved, both ways, AirDrop
/// included. Its own widget so the Nearby tab's Files page shows the very same
/// list the Profile opens.
class FileTransferList extends ConsumerWidget {
  const FileTransferList({super.key, this.bottomPadding = 40});

  /// 40 as a screen of its own; 140 inside a tab, above the floating bar.
  final double bottomPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final transfers = ref.watch(fileTransferControllerProvider).values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final active = transfers.where((task) => task.active).toList();
    final history = transfers.where((task) => !task.active).toList();
    if (transfers.isEmpty) return _EmptyState(label: t.fileTransfersEmpty);
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPadding),
      children: [
        if (active.isNotEmpty) ...[
          _SectionLabel(t.fileTransfersActive),
          for (final task in active) ...[
            _TransferCard(task: task),
            const SizedBox(height: 10),
          ],
        ],
        if (history.isNotEmpty) ...[
          _SectionLabel(t.fileTransfersHistory),
          for (final task in history) ...[
            _TransferCard(task: task),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

class _TransferCard extends ConsumerWidget {
  const _TransferCard({required this.task});

  final FileTransferTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final controller = ref.read(fileTransferControllerProvider.notifier);
    final outgoing = task.direction == FileTransferDirection.outgoing;

    return GestureDetector(
      onLongPressStart: (details) =>
          unawaited(_menu(context, ref, details.globalPosition)),
      child: GlassCard(
        onTap: task.status == FileTransferStatus.completed &&
                task.filePath.isNotEmpty
            ? () => OpenFilex.open(
                  task.filePath,
                  type: fileMimeType(task.fileName),
                )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _tone(task.status).withValues(alpha: 0.15),
                  ),
                  child: Icon(
                    outgoing
                        ? Icons.upload_file_rounded
                        : Icons.download_rounded,
                    color: _tone(task.status),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textOnGlass,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_statusLabel(t, task.status)} · '
                        '${_formatBytes(task.bytesTotal)}',
                        style: TextStyle(
                          color: AppColors.textOnGlassDim,
                          fontSize: 11.5,
                        ),
                      ),
                      if (task.source == FileTransferSource.airdrop)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            t.airdropFromLabel(task.peerName ?? '—'),
                            style: TextStyle(
                              color: AppColors.brandPrimary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (outgoing) ..._actions(t, controller, ref),
              ],
            ),
            if (task.active || task.status == FileTransferStatus.failed) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: task.totalUnits == 0 ? null : task.progress,
                  minHeight: 5,
                  backgroundColor: AppColors.glass(0.08),
                  valueColor: AlwaysStoppedAnimation(_tone(task.status)),
                ),
              ),
            ],
            if (task.error != null) ...[
              const SizedBox(height: 8),
              Text(
                task.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.danger, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Hold a finished file: send it on by AirDrop, or — for one AirDrop
  /// brought in — delete it from the phone. Its history line stays, marked.
  Future<void> _menu(BuildContext context, WidgetRef ref, Offset at) async {
    final t = AppLocalizations.of(context);
    final path = task.filePath;
    if (task.status != FileTransferStatus.completed ||
        !MediaPaths.existsOrNull(path)) {
      return;
    }
    final deletable = task.source == FileTransferSource.airdrop &&
        task.direction == FileTransferDirection.incoming;
    final action = await showContextPopup<String>(
      context: context,
      globalPosition: at,
      items: [
        PopupMenuItem<String>(
          value: 'airdrop',
          height: 44,
          child: Text(
            t.airdropAction,
            style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
          ),
        ),
        if (deletable)
          PopupMenuItem<String>(
            value: 'delete',
            height: 44,
            child: Text(
              t.chatDeleteAction,
              style: const TextStyle(color: AppColors.danger, fontSize: 14),
            ),
          ),
      ],
    );
    if (action == null || !context.mounted) return;
    if (action == 'airdrop') {
      final source =
          await AirDropSource.fromFile(File(path), name: task.fileName);
      if (!context.mounted) return;
      await startAirDropSend(context, ref, files: [source]);
      return;
    }
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone is the outcome that was asked for.
    }
    MediaPaths.forget(path);
    ref.read(airdropHistoryProvider.notifier).markDeleted(path);
    await ref.read(fileTransferControllerProvider.notifier).remove(task.id);
  }

  List<Widget> _actions(
    AppLocalizations t,
    FileTransferController controller,
    WidgetRef ref,
  ) {
    switch (task.status) {
      case FileTransferStatus.transferring:
        return [
          _Action(
            tooltip: t.fileTransferPause,
            icon: Icons.pause_rounded,
            onTap: () => controller.pause(task.id),
          ),
          _Action(
            tooltip: t.cancel,
            icon: Icons.close_rounded,
            onTap: () => controller.cancel(task.id),
          ),
        ];
      case FileTransferStatus.paused:
        return [
          _Action(
            tooltip: t.fileTransferResume,
            icon: Icons.play_arrow_rounded,
            onTap: () => controller.resume(task.id),
          ),
          _Action(
            tooltip: t.cancel,
            icon: Icons.close_rounded,
            onTap: () => controller.cancel(task.id),
          ),
        ];
      case FileTransferStatus.queued:
      case FileTransferStatus.failed:
        // An AirDrop is retried from the AirDrop page, with the person there
        // to say yes; this button would resend it into a chat.
        if (task.source == FileTransferSource.airdrop) return const [];
        return [
          _Action(
            tooltip: t.fileTransferRetry,
            icon: Icons.refresh_rounded,
            onTap: () {
              final messaging = ref.read(messagingServiceProvider);
              // Pressed by hand, so a transfer held for Wi-Fi may come now.
              messaging.resumeMediaInbox();
              messaging.retryFileTransfer(task.id);
            },
          ),
          _Action(
            tooltip: t.cancel,
            icon: Icons.close_rounded,
            onTap: () => controller.cancel(task.id),
          ),
        ];
      case FileTransferStatus.completed:
      case FileTransferStatus.canceled:
        return const [];
    }
  }

  static Color _tone(FileTransferStatus status) => switch (status) {
        FileTransferStatus.completed => AppColors.online,
        FileTransferStatus.failed ||
        FileTransferStatus.canceled =>
          AppColors.danger,
        FileTransferStatus.paused ||
        FileTransferStatus.queued =>
          AppColors.warning,
        FileTransferStatus.transferring => AppColors.brandPrimary,
      };

  static String _statusLabel(
    AppLocalizations t,
    FileTransferStatus status,
  ) =>
      switch (status) {
        FileTransferStatus.queued => t.fileTransferQueued,
        FileTransferStatus.transferring => t.fileTransferRunning,
        FileTransferStatus.paused => t.fileTransferPaused,
        FileTransferStatus.completed => t.fileTransferCompleted,
        FileTransferStatus.failed => t.fileTransferFailed,
        FileTransferStatus.canceled => t.fileTransferCanceled,
      };

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        color: AppColors.textOnGlass,
        visualDensity: VisualDensity.compact,
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: AppColors.textOnGlassFaint,
            fontSize: 11,
            letterSpacing: 1.1,
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.swap_vert_circle_rounded,
                size: 54,
                color: AppColors.textOnGlassFaint,
              ),
              const SizedBox(height: 14),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textOnGlassDim),
              ),
            ],
          ),
        ),
      );
}
