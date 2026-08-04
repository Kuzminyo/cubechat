import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/identity/avatar_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/image_editor.dart';
import '../../chat/presentation/widgets/media_picker_sheet.dart';

Future<void> pickProfileAvatar(BuildContext context, WidgetRef ref) async {
  final t = AppLocalizations.of(context);
  final result = await showGlassSheet<MediaPickerResult>(
    context: context,
    useRootNavigator: true,
    builder: (_) => const MediaPickerSheet(),
  );
  if (result is! MediaPickerAssets || result.assets.isEmpty) return;

  // Asked for at the size the controller keeps, not below it. This used to
  // pull 1024 while the store had been raised to full HD, so the extra
  // resolution was thrown away before it ever arrived — the cover looked no
  // sharper for it.
  final preview = await result.assets.first.thumbnailDataWithSize(
    const ThumbnailSize(
      AvatarController.storedSize,
      AvatarController.storedSize,
    ),
    quality: 95,
  );
  if (preview == null) {
    if (context.mounted) showGlassToast(context, t.avatarFailed);
    return;
  }
  if (!context.mounted) return;

  // Choose the part of the picture that becomes the avatar, on the picture
  // itself. What is stored is a square — the circle in a list, the cover across
  // the top of the profile — and until now the square was taken from the middle
  // of whatever was picked, which on a portrait photo is a crop nobody asked
  // for and reads as the app having zoomed in on you.
  final cropped = await openImageEditor(context, preview);
  // Backing out of the crop backs out of the change: the picture was never
  // what you wanted, and setting the automatic centre crop anyway is the thing
  // this step exists to stop.
  if (cropped == null || !context.mounted) return;

  final ok = await ref.read(avatarProvider.notifier).setFromBytes(cropped);
  if (!ok && context.mounted) showGlassToast(context, t.avatarFailed);
}

/// The avatar, opened. Tapping the circle in the profile lands here through a
/// Hero, so the small circle grows into the big one rather than cutting to a
/// new screen.
///
/// Doubles as the place to change or remove the picture: the profile circle
/// stays a plain tap target with no badges or long-press secrets hanging off
/// it, and every avatar action lives in the one screen that is about the
/// avatar.
class AvatarScreen extends ConsumerWidget {
  const AvatarScreen({
    super.key,
    required this.seed,
    required this.label,
    this.heroTag = 'profile-avatar',
  });

  final String seed;
  final String label;
  final String heroTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final bytes = ref.watch(avatarProvider);
    final side = MediaQuery.sizeOf(context).width * 0.7;

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: IdentityAvatar(
                  seed: seed,
                  label: label,
                  size: side,
                  heroTag: heroTag,
                  imageBytes: bytes,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Row(
                children: [
                  Expanded(
                    child: PillButton(
                      label: bytes == null ? t.avatarSet : t.avatarChange,
                      icon: Icons.photo_camera_back_outlined,
                      onTap: () => pickProfileAvatar(context, ref),
                    ),
                  ),
                  if (bytes != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: PillButton(
                        label: t.avatarRemove,
                        icon: Icons.delete_outline,
                        onTap: () => _remove(context, ref),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    final yes = await confirmAction(
      context,
      title: t.avatarRemove,
      message: t.avatarRemoveConfirm,
      confirmLabel: t.avatarRemove,
    );
    if (!yes) return;
    await ref.read(avatarProvider.notifier).clear();
  }
}
