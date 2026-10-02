import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/image_encode.dart';
import '../../../core/util/media_storage.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../../airdrop/data/share_inbox.dart';
import '../../chats/data/saved_messages.dart';
import '../../chats/models/chat.dart';
import '../../chats/presentation/chats_list_screen.dart';
import '../../chats/presentation/widgets/chat_picker_screen.dart';
import '../../profile/data/media_quality_controller.dart';
import '../domain/share_plan.dart';

/// "Share → CubeChat" from another app: choose chats, the way forwarding does,
/// and send it there.
///
/// It used to open the app and nothing more for a link — a share with no file
/// in it was dropped on the platform side — and to hand files only to AirDrop,
/// which is for the people standing next to you. Now it is the forward picker:
/// Saved first, then every chat, as many as you tick. AirDrop is still there,
/// as the row on top, when there are files to hand over.
///
/// One chat chosen opens it afterwards, the way Telegram lands you in the
/// conversation you shared into; several leave you where you were with a
/// toast.
Future<void> shareIntoChats(
  BuildContext context,
  WidgetRef ref,
  SharedBundle bundle, {
  required VoidCallback onAirDrop,
}) async {
  final t = AppLocalizations.of(context);
  final targets = await showChatPicker(
    context,
    title: t.shareIntoTitle,
    includeSaved: true,
    // Rooms take text and pictures; they are offered only when nothing in
    // the share would be left behind.
    includeChannels: bundle.roomsCanTakeAll,
    header: bundle.files.isEmpty
        ? null
        : (picker) => _AirDropRow(
              onTap: () {
                Navigator.of(picker).pop();
                onAirDrop();
              },
            ),
  );
  if (targets.isEmpty) return;
  var failed = 0;
  for (final target in targets) {
    try {
      await sendSharedTo(ref, target, bundle);
    } catch (e) {
      failed++;
      // The error's type only: what was shared is somebody's own content.
      DebugLog.instance.log('SHARE', 'into a chat failed: ${e.runtimeType}');
    }
  }
  if (!context.mounted) return;
  showGlassToast(
    context,
    failed == 0 ? t.shareSent : t.shareFailed,
    tone: failed == 0 ? ToastTone.success : ToastTone.danger,
  );
  if (targets.length == 1) {
    await GoRouter.of(context).push(routeForChat(targets.single));
  }
}

/// Send [bundle] into [target], step by step — see [planShare].
Future<void> sendSharedTo(
  WidgetRef ref,
  Chat target,
  SharedBundle bundle,
) async {
  final messaging = ref.read(messagingServiceProvider);
  final saved = isSavedChat(target.id);
  final notes = ref.read(savedMessagesControllerProvider);
  for (final step in planShare(bundle, toChannel: target.isChannel)) {
    switch (step) {
      case ShareTextStep(:final text):
        if (saved) {
          await notes.saveText(text);
        } else if (target.isChannel) {
          await messaging.sendChannelText(target.id, text);
        } else {
          await messaging.sendText(target.id, text);
        }
      case SharePictureStep(:final file):
        final original = await File(file.path).readAsBytes();
        if (saved) {
          // A note on this phone: kept as it came, nothing to fit through
          // Bluetooth.
          await notes.saveImage(original, mime: file.mime);
          continue;
        }
        // Fitted to the mesh budget, the way the gallery's and the camera's
        // pictures are — a phone photo straight off the camera is many times
        // what a Bluetooth link can carry.
        final quality =
            await ref.read(mediaQualityProvider.notifier).resolved();
        final wire = await encodeBytesForMesh(original, quality: quality);
        if (wire == null) throw StateError('picture too large');
        final cached = await _cacheSent(wire);
        if (target.isChannel) {
          await messaging.sendChannelImage(
            target.id,
            bytes: wire,
            mime: 'image/jpeg',
            cachedPath: cached,
          );
        } else {
          await messaging.sendImage(
            target.id,
            bytes: wire,
            mime: 'image/jpeg',
            cachedPath: cached,
          );
        }
      case ShareFileStep(:final file):
        if (saved) {
          await notes.saveFile(
            File(file.path),
            fileName: file.name,
            mime: file.mime,
          );
        } else {
          await messaging.sendFile(
            target.id,
            file: File(file.path),
            fileName: file.name,
            mime: file.mime,
          );
        }
    }
  }
}

/// The sent copy our own bubble draws from — the share's file is in the cache
/// and may be cleared, and it is the original, not what went out.
Future<String?> _cacheSent(List<int> bytes) async {
  try {
    final dir = await sentImagesDirectory();
    final file =
        File('${dir.path}/share-${DateTime.now().microsecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

class _AirDropRow extends StatelessWidget {
  const _AirDropRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return FloatingGlass(
      blur: false,
      borderRadius: 18,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.brandPrimary.withValues(alpha: 0.16),
                border: Border.all(
                  color: AppColors.brandPrimary.withValues(alpha: 0.38),
                ),
              ),
              child: Icon(
                Icons.wifi_tethering_rounded,
                color: AppColors.brandPrimary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.shareNearbyAirDrop,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.shareNearbyAirDropHint,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textOnGlassFaint,
            ),
          ],
        ),
      ),
    );
  }
}
