import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../backup/data/desktop_link_service.dart';
import '../../backup/data/phone_transfer_socket_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../channels/data/channel_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/channel_qr_payload.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key, this.initialCode});

  /// A code that arrived without the camera — a cubechat.tech link opened by
  /// Google Lens or the system camera. Handled exactly as if it had been
  /// scanned here, so a transfer or a computer link works from either.
  final String? initialCode;

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen>
    with WidgetsBindingObserver {
  QRCodeDartScanController? _controller;
  bool _cameraVisible = false;
  bool _restartOnResume = false;
  bool _requestingCamera = false;
  bool _processing = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final code = widget.initialCode;
    if (code != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_handle(code)));
    } else {
      unawaited(_startCamera());
    }
  }

  Future<void> _startCamera() async {
    if (_requestingCamera || !mounted) return;
    _requestingCamera = true;
    try {
      // Ask before mounting the scanner: the system permission sheet itself
      // makes the app inactive, which used to interrupt camera initialization.
      final permission = await Permission.camera.request();
      if (!mounted) return;
      setState(() {
        _cameraError = permission.isGranted ? null : 'permission';
        _controller = permission.isGranted ? QRCodeDartScanController() : null;
        _cameraVisible = permission.isGranted;
      });
    } catch (_) {
      if (mounted) setState(() => _cameraError = 'camera');
    } finally {
      _requestingCamera = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_cameraVisible) {
        _restartOnResume = true;
        setState(() => _cameraVisible = false);
      }
    } else if (state == AppLifecycleState.resumed && _restartOnResume) {
      _restartOnResume = false;
      if (!_processing) unawaited(_startCamera());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // QRCodeDartScanView owns disposal of the controller passed to it.
    super.dispose();
  }

  Future<void> _onCapture(Result result) => _handle(result.text);

  Future<void> _handle(String text) async {
    if (_processing || !mounted) return;
    _processing = true;
    final t = AppLocalizations.of(context);
    try {
      if (_cameraVisible) await _controller?.stopScan();
      if (!mounted) return;
      // A computer asking for a copy of this account. Checked before the
      // phone-to-phone code: the two go in opposite directions, and this one
      // sends rather than receives — nothing here is replaced.
      final computer = DesktopLinkPayload.tryDecode(text);
      if (computer != null) {
        final confirmed = await confirmAction(
          context,
          title: t.desktopLinkConfirmTitle,
          message: t.desktopLinkConfirmMessage,
          confirmLabel: t.desktopLinkConfirmAction,
        );
        if (!confirmed) {
          await _resume();
          return;
        }
        if (!mounted) return;
        // Every step shown as it happens. One "sending" toast used to stand
        // for minutes of copying, the transfer and the computer's restore,
        // and read as hung (2026-10-12).
        final progress =
            ValueNotifier(const LinkProgress(LinkStage.connecting));
        final navigator = Navigator.of(context, rootNavigator: true);
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            useRootNavigator: true,
            builder: (_) => PopScope(
              canPop: false,
              child: _LinkProgressDialog(progress: progress),
            ),
          ),
        );
        try {
          await ref
              .read(desktopLinkServiceProvider)
              .sendTo(computer, onProgress: (p) => progress.value = p);
        } catch (error) {
          navigator.pop();
          progress.dispose();
          if (!mounted) return;
          // Nothing answered on any address the code names: almost always
          // another Wi-Fi, or the computer's firewall. Said in words rather
          // than as "SocketException: Connection timed out (OS Error…)".
          final unreachable = error is SocketException;
          showGlassToast(
            context,
            unreachable
                ? t.desktopLinkUnreachable
                : '$error'
                    .replaceFirst(RegExp(r'^\w*(Error|Exception):\s*'), ''),
            tone: ToastTone.danger,
            duration: Duration(seconds: unreachable ? 8 : 5),
          );
          await _resume();
          return;
        }
        navigator.pop();
        progress.dispose();
        if (!mounted) return;
        showGlassToast(context, t.desktopLinkSent, tone: ToastTone.success);
        context.pop();
        return;
      }

      final transfer = PhoneTransferPayload.tryDecode(text);
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
        if (!mounted) return;
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

      final channelInvite = ChannelQrPayload.tryDecode(text);
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

      final pubkey =
          await ref.read(messagingServiceProvider).addContactFromCard(text);
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
    if (_cameraVisible) {
      await _controller?.startScan();
    } else {
      await _startCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_cameraVisible)
            QRCodeDartScanView(
              key: ObjectKey(_controller),
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
                        onTap: () {
                          if (_cameraVisible) {
                            unawaited(_controller?.toggleFlash());
                          }
                        },
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (_cameraError != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => unawaited(_startCamera()),
                          child: Text(t.bleRetry),
                        ),
                        TextButton(
                          onPressed: () {
                            _restartOnResume = true;
                            unawaited(openAppSettings());
                          },
                          child: Text(t.mediaOpenSettings),
                        ),
                      ],
                    ),
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

/// The phone's account on its way to a computer, step by step. Cannot be
/// dismissed: leaving would not stop the transfer, only hide it.
class _LinkProgressDialog extends StatelessWidget {
  const _LinkProgressDialog({required this.progress});

  final ValueListenable<LinkProgress> progress;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: AppColors.bgTop,
      title: Text(
        t.desktopLinkTitle,
        style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
      ),
      content: ValueListenableBuilder<LinkProgress>(
        valueListenable: progress,
        builder: (context, p, _) {
          final text = switch (p.stage) {
            LinkStage.waiting || LinkStage.connecting => t.desktopLinkFinding,
            LinkStage.preparing => t.desktopLinkPreparing,
            LinkStage.transferring =>
              t.desktopLinkSendingPercent((p.fraction * 100).floor()),
            LinkStage.restoring => t.desktopLinkComputerRestoring,
          };
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  // A bar that fills only while there is something to count.
                  value: p.stage == LinkStage.transferring ? p.fraction : null,
                  minHeight: 5,
                  color: AppColors.brandPrimary,
                  backgroundColor: AppColors.glass(0.12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
