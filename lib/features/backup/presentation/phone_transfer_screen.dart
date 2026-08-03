import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../qr/presentation/qr_display.dart';
import '../data/phone_transfer_socket_service.dart';

class PhoneTransferScreen extends ConsumerStatefulWidget {
  const PhoneTransferScreen({super.key});

  @override
  ConsumerState<PhoneTransferScreen> createState() =>
      _PhoneTransferScreenState();
}

class _PhoneTransferScreenState extends ConsumerState<PhoneTransferScreen> {
  PhoneTransferSession? _session;
  bool _preparing = false;

  Future<void> _start() async {
    if (_preparing) return;
    setState(() => _preparing = true);
    try {
      await _session?.close();
      final session =
          await ref.read(phoneTransferServiceProvider).startSending();
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() => _session = session);
    } catch (error) {
      if (mounted) {
        showGlassToast(
          context,
          '${AppLocalizations.of(context).phoneTransferFailed}: $error',
          tone: ToastTone.danger,
        );
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  void dispose() {
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textOnGlass,
        title: Text(t.phoneTransferTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          GlassCard(
            child: Column(
              children: [
                const Icon(
                  Icons.phonelink_rounded,
                  size: 42,
                  color: AppColors.brandPrimary,
                ),
                const SizedBox(height: 12),
                Text(
                  t.phoneTransferIntro,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t.phoneTransferSameWifi,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_session == null)
            FilledButton.icon(
              onPressed: _preparing ? null : _start,
              icon: _preparing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.qr_code_2_rounded),
              label: Text(
                _preparing ? t.phoneTransferPreparing : t.phoneTransferSend,
              ),
            )
          else
            GlassCard(
              child: Column(
                children: [
                  Text(
                    t.phoneTransferReady,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FittedBox(child: QrDisplay(data: _session!.payload)),
                  const SizedBox(height: 10),
                  Text(
                    '${(_session!.bytes / 1024).ceil()} KB',
                    style: TextStyle(color: AppColors.textOnGlassDim),
                  ),
                  TextButton(
                    onPressed: _start,
                    child: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => context.push('/qr/scan'),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: Text(t.phoneTransferReceive),
          ),
        ],
      ),
    );
  }
}
