import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/domain/message_preview.dart';
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

  /// The words of the reported message, as the moderator should read them.
  ///
  /// A sticker, a shared location or a contact card is a `cubechat:` URI in
  /// the text field; sending that raw would put somebody's coordinates in
  /// the moderation bot for no benefit, so those go as the same one-line
  /// preview the chat list shows. Media go as their caption, if any.
  String? _text(Message? m, AppLocalizations t) {
    if (m == null) return null;
    if (m.kind != MessageKind.text) return m.imageCaption;
    if (m.isSticker || m.text.startsWith('cubechat:')) {
      return messagePreview(m, t);
    }
    return m.text;
  }

  /// "Send" promises three things, and the two local ones do not wait on the
  /// network's verdict (review of the Codex handoff, 2026-09-25): the person
  /// asked for this author to be gone from their screen, and a server that
  /// is down, or refuses the payload, is no reason to keep showing them.
  Future<void> _submit() async {
    if (_sending) return;
    setState(() => _sending = true);
    final t = AppLocalizations.of(context);
    final m = widget.message;
    // The note field only exists under "Other"; text typed there before
    // switching to another reason is not part of the report.
    final note = _reason == ReportReason.other ? _note.text.trim() : '';
    final report = ModerationReport(
      reason: _reason,
      note: note.isEmpty ? null : note,
      context: widget.reportContext,
      target: widget.targetHex,
      targetNpub: widget.targetNpub,
      channelId: widget.channelId,
      messageText: _text(m, t),
      messageKind: _kind(m),
      messageSentAt: m?.sentAt.millisecondsSinceEpoch,
    );
    // null: refused for good (400/401) or not even queued.
    bool? sent;
    try {
      // send() writes to encrypted storage before trying the network.
      sent = await ref.read(reportClientProvider).send(report);
    } catch (e) {
      DebugLog.instance.log('REPORT', 'report not accepted: $e');
    }
    final target = widget.targetHex;
    final blocks = (widget.reportContext == ReportContext.direct ||
            widget.reportContext == ReportContext.airdrop) &&
        target != null;
    try {
      if (blocks) {
        await ref
            .read(knownPeersControllerProvider.notifier)
            .setBlocked(target, true);
      }
      if (widget.reportContext == ReportContext.channel &&
          m?.authorId != null) {
        await ref.read(hiddenAuthorsProvider.notifier).hide(m!.authorId!);
      }
    } catch (e) {
      DebugLog.instance.log('REPORT', 'could not block after a report: $e');
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
      switch (sent) {
        true when blocks => '${t.reportSent} ${t.reportBlockedToo}',
        true => t.reportSent,
        false => t.reportQueued,
        null => t.reportFailed,
      },
      icon: Icons.flag_rounded,
      tone: sent == null ? ToastTone.danger : ToastTone.success,
    );
    Navigator.of(context).pop(true);
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
