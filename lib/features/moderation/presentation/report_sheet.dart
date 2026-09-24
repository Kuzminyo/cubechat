import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/hidden_authors.dart';
import '../data/report_client.dart';
import '../domain/report.dart';

Future<bool> showReportSheet(
  BuildContext context, {
  required ReportContext reportContext,
  String? targetHex,
  String? targetNpub,
  String? channelId,
  Message? message,
  String? chatId,
}) async {
  final result = await showGlassSheet<bool>(
    context: context,
    builder: (_) => _ReportSheet(
      reportContext: reportContext,
      targetHex: targetHex,
      targetNpub: targetNpub,
      channelId: channelId,
      message: message,
      chatId: chatId,
    ),
  );
  return result ?? false;
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({
    required this.reportContext,
    this.targetHex,
    this.targetNpub,
    this.channelId,
    this.message,
    this.chatId,
  });

  final ReportContext reportContext;
  final String? targetHex;
  final String? targetNpub;
  final String? channelId;
  final Message? message;
  final String? chatId;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  ReportReason _reason = ReportReason.spam;
  final _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  ReportedKind? _kind(Message? m) {
    if (m == null) return null;
    if (m.isSticker) return ReportedKind.sticker;
    if (m.isCircle) return ReportedKind.video;
    return switch (m.kind) {
      MessageKind.text => ReportedKind.text,
      MessageKind.image => m.imageMime?.startsWith('video/') == true
          ? ReportedKind.video
          : ReportedKind.photo,
      MessageKind.audio => ReportedKind.voice,
      MessageKind.file => ReportedKind.file,
      MessageKind.poll => ReportedKind.other,
    };
  }

  Future<void> _submit() async {
    if (_sending) return;
    setState(() => _sending = true);
    final t = AppLocalizations.of(context);
    final m = widget.message;
    final report = ModerationReport(
      reason: _reason,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      context: widget.reportContext,
      target: widget.targetHex,
      targetNpub: widget.targetNpub,
      channelId: widget.channelId,
      messageText: m?.kind == MessageKind.text ? m?.text : m?.imageCaption,
      messageKind: _kind(m),
      messageSentAt: m == null ? null : m.sentAt.millisecondsSinceEpoch ~/ 1000,
    );
    try {
      // send() writes to encrypted storage before trying the network.
      final sent = await ref.read(reportClientProvider).send(report);
      final target = widget.targetHex;
      if ((widget.reportContext == ReportContext.direct ||
              widget.reportContext == ReportContext.airdrop) &&
          target != null) {
        await ref
            .read(knownPeersControllerProvider.notifier)
            .setBlocked(target, true);
      }
      if (widget.reportContext == ReportContext.channel &&
          m?.authorId != null) {
        await ref.read(hiddenAuthorsProvider.notifier).hide(m!.authorId!);
      }
      if (m != null && widget.chatId != null) {
        ref.read(messagesControllerProvider.notifier).deleteLocal(
              widget.chatId!,
              m.id,
            );
      }
      if (!mounted) return;
      showGlassToast(
        context,
        sent ? t.reportSent : t.reportQueued,
        icon: Icons.flag_rounded,
        tone: ToastTone.success,
      );
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      showGlassToast(context, t.reportFailed, tone: ToastTone.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final labels = <ReportReason, String>{
      ReportReason.spam: t.reportReasonSpam,
      ReportReason.abuse: t.reportReasonAbuse,
      ReportReason.violence: t.reportReasonViolence,
      ReportReason.sexual: t.reportReasonSexual,
      ReportReason.other: t.reportReasonOther,
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.reportTitle, style: AppTypography.heading(size: 19)),
            const SizedBox(height: 12),
            for (final reason in ReportReason.values)
              RadioListTile<ReportReason>(
                title: Text(
                  labels[reason]!,
                  style: TextStyle(color: AppColors.textOnGlass),
                ),
                value: reason,
                groupValue: _reason,
                activeColor: AppColors.brandPrimary,
                onChanged: _sending
                    ? null
                    : (value) => setState(() => _reason = value!),
              ),
            if (_reason == ReportReason.other)
              TextField(
                controller: _note,
                maxLength: ModerationReport.noteMaxChars,
                maxLines: 3,
                style: TextStyle(color: AppColors.textOnGlass),
                decoration: InputDecoration(hintText: t.reportNoteHint),
              ),
            const SizedBox(height: 8),
            Text(t.reportDisclosure,
                style: TextStyle(color: AppColors.textOnGlassDim)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sending ? null : () => unawaited(_submit()),
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.flag_rounded),
              label: Text(t.reportSend),
            ),
          ],
        ),
      ),
    );
  }
}
