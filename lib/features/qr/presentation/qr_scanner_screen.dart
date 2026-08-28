import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../backup/data/phone_transfer_socket_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../channels/data/channel_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/channel_qr_payload.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  final _controller = QRCodeDartScanController();
  bool _processing = false;
  String? _cameraError;

  Future<void> _onCapture(Result result) async {
    if (_processing || !mounted) return;
    _processing = true;
    final t = AppLocalizations.of(context);
    await _controller.stopScan();

    try {
      final transfer = PhoneTransferPayload.tryDecode(result.text);
      if (transfer != null) {
        final confirmed = await confirmAction(
          context,
          title: t.phoneTransferConfirmTitle,
          message: t.phoneTransferConfirmMessage,
          confirmLabel: t.phoneTransferConfirmAction,
          destructive: true,
        );
        if (!confirmed) {
          await _resume();
          return;
        }
        showGlassToast(
          context,
          t.phoneTransferPreparing,
          tone: ToastTone.neutral,
        );
        // Caught here, not by the handlers below.
        //
        // Everything that can go wrong with a transfer — the other phone off
        // the network, a connection refused, a link whose one use is spent, a
        // backup too large to carry — used to fall through to the generic
        // arms at the bottom and come back as "invalid QR code", or, for a
        // StateError, as "this is your own contact card". So a transfer that
        // failed for a plain network reason told you the thing you had just
        // scanned was not a transfer at all, which is precisely "the QR
        // transfer does not work".
        try {
          await ref.read(phoneTransferServiceProvider).receive(transfer);
        } catch (error) {
          if (!mounted) return;
          showGlassToast(
            context,
            '$error'.replaceFirst(RegExp(r'^\w*(Error|Exception):\s*'), ''),
            tone: ToastTone.danger,
            duration: const Duration(seconds: 5),
          );
          await _resume();
          return;
        }
        if (!mounted) return;
        showGlassToast(
          context,
          t.phoneTransferSuccess,
          tone: ToastTone.success,
        );
        context.go('/chats');
        return;
      }

      final channelInvite = ChannelQrPayload.tryDecode(result.text);
      if (channelInvite != null) {
        final channel = await ref
            .read(channelControllerProvider.notifier)
            .joinWithKey(channelInvite.name, channelInvite.key);
        if (!mounted) return;
        showGlassToast(
          context,
          t.qrChannelAdded(channel.name),
          tone: ToastTone.success,
        );
        final pathName = Uri.encodeComponent(channel.name.substring(1));
        context.pushReplacement('/channel/$pathName');
        return;
      }

      final pubkey = await ref
          .read(messagingServiceProvider)
          .addContactFromCard(result.text);
      if (!mounted) return;
      final name =
          ref.read(knownPeersControllerProvider)[pubkey]?.displayName ?? '';
      showGlassToast(
        context,
        t.contactAdded(name),
        tone: ToastTone.success,
      );
      context.pushReplacement(
        '/chat/$pubkey?name=${Uri.encodeComponent(name)}',
      );
    } on StateError {
      if (!mounted) return;
      showGlassToast(context, t.contactOwnCard, tone: ToastTone.danger);
      await _resume();
    } on FormatException {
      if (!mounted) return;
      showGlassToast(context, t.qrInvalid, tone: ToastTone.danger);
      await _resume();
    } catch (_) {
      if (!mounted) return;
      showGlassToast(context, t.qrInvalid, tone: ToastTone.danger);
      await _resume();
    }
  }

  Future<void> _resume() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    _processing = false;
    await _controller.startScan();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          QRCodeDartScanView(
            controller: _controller,
            typeScan: TypeScan.live,
            formats: const [BarcodeFormat.qrCode],
            resolutionPreset: QRCodeDartScanResolutionPreset.high,
            croppingStrategy: CroppingStrategy.cropCenterSquare(
              squareSizeFactor: 0.72,
            ),
            onCameraError: (error) {
              if (mounted) setState(() => _cameraError = error);
            },
            onCapture: (result) => unawaited(_onCapture(result)),
          ),
          const _ScanShade(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _RoundButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip:
                            MaterialLocalizations.of(context).backButtonTooltip,
                        onTap: () => context.pop(),
                      ),
                      Text(
                        t.qrScanTitle,
                        style: AppTypography.heading(
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                      _RoundButton(
                        icon: Icons.flashlight_on_rounded,
                        tooltip: t.qrFlash,
                        onTap: () => _controller.toggleFlash(),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    _cameraError == null ? t.qrScanHint : t.qrCameraError,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _cameraError == null
                          ? AppColors.ink(0.82)
                          : AppColors.danger,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanShade extends StatelessWidget {
  const _ScanShade();

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(painter: _ScanShadePainter()),
      );
}

class _ScanShadePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width * 0.72;
    final scan = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side,
      height: side,
    );
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(scan, const Radius.circular(24)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black54);
    canvas.drawRRect(
      RRect.fromRectAndRadius(scan, const Radius.circular(24)),
      Paint()
        ..color = AppColors.brandPrimary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
        tooltip: tooltip,
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.48),
        ),
      );
}
