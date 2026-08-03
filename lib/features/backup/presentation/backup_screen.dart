import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/backup_service.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;

  Future<void> _create() async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _BackupPasswordDialog(confirm: true),
    );
    if (password == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes =
          await ref.read(backupServiceProvider).create(password: password);
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: t.backupSaveTitle,
        fileName: 'cubechat-$day.cchatbackup',
        type: FileType.custom,
        allowedExtensions: const ['cchatbackup'],
        bytes: bytes,
      );
      if (!mounted || path == null) return;
      showGlassToast(context, t.backupSaved, tone: ToastTone.success);
    } catch (_) {
      if (!mounted) return;
      showGlassToast(context, t.backupFailed, tone: ToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    // FileType.any, not a filter on `.cchatbackup`.
    //
    // Android's picker filters by MIME type, and a made-up extension maps to
    // none — so the file we had just told the user to save was the one file
    // they could not select. The picker opened onto its own backup greyed out,
    // which from the outside is indistinguishable from a button that does
    // nothing, and that is exactly how it was reported.
    //
    // Nothing is lost by dropping the filter: the format is checked properly a
    // moment later. BackupCodec rejects anything without its magic header, and
    // the payload is authenticated, so a wrong file fails as `backupInvalid`
    // rather than being half-applied.
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    final file = picked?.files.singleOrNull;
    if (file == null || !mounted) return;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || !mounted) return;

    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _BackupPasswordDialog(confirm: false),
    );
    if (password == null || !mounted) return;
    final t = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: t.backupRestoreConfirmTitle,
      message: t.backupRestoreConfirmMessage,
      confirmLabel: t.backupRestoreConfirmAction,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(backupServiceProvider).restore(
            bytes,
            password: password,
          );
      if (!mounted) return;
      showGlassToast(context, t.backupRestored, tone: ToastTone.success);
      context.go('/profile');
    } on FormatException {
      if (!mounted) return;
      showGlassToast(context, t.backupInvalid, tone: ToastTone.danger);
    } catch (_) {
      if (!mounted) return;
      showGlassToast(context, t.backupFailed, tone: ToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          t.backupTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          GlassCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lock_rounded,
                  color: AppColors.brandPrimary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t.backupExplainer,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _BackupActionCard(
            icon: Icons.cloud_upload_outlined,
            title: t.backupCreate,
            subtitle: t.backupCreateSubtitle,
            onTap: _busy ? null : _create,
          ),
          const SizedBox(height: 10),
          _BackupActionCard(
            icon: Icons.settings_backup_restore_rounded,
            title: t.backupRestore,
            subtitle: t.backupRestoreSubtitle,
            danger: true,
            onTap: _busy ? null : _restore,
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(
              child: CircularProgressIndicator(color: AppColors.brandPrimary),
            ),
          ],
        ],
      ),
    );
  }
}

class _BackupActionCard extends StatelessWidget {
  const _BackupActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => GlassCard(
        onTap: onTap,
        child: Row(
          children: [
            Icon(
              icon,
              color: danger ? AppColors.warning : AppColors.brandPrimary,
              size: 28,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.textOnGlassFaint),
          ],
        ),
      );
}

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.confirm});

  final bool confirm;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    final t = AppLocalizations.of(context);
    if (_password.text.length < 8) {
      showGlassToast(context, t.backupPasswordShort, tone: ToastTone.danger);
      return;
    }
    if (widget.confirm && _password.text != _confirmation.text) {
      showGlassToast(context, t.backupPasswordMismatch, tone: ToastTone.danger);
      return;
    }
    Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: AppColors.bgTop,
      title: Text(
        t.backupPasswordTitle,
        style: TextStyle(color: AppColors.textOnGlass),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _password,
            obscureText: _obscure,
            autofocus: true,
            onSubmitted: (_) {
              if (!widget.confirm) _submit();
            },
            decoration: InputDecoration(
              labelText: t.backupPasswordHint,
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure ? Icons.visibility : Icons.visibility_off,
                ),
              ),
            ),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _confirmation,
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: t.backupConfirmPassword,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirm ? t.backupCreate : t.backupRestore),
        ),
      ],
    );
  }
}
