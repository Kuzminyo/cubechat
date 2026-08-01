import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/identity/avatar_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/media_picker_sheet.dart';

Future<void> pickProfileAvatar(BuildContext context, WidgetRef ref) async {
  final t = AppLocalizations.of(context);
  final result = await showModalBottomSheet<MediaPickerResult>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.bgTop,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => const MediaPickerSheet(),
  );
  if (result is! MediaPickerAssets || result.assets.isEmpty) return;

  // A preview is plenty: the controller crops to a square and keeps it at 1024
  // anyway, so pulling the full-resolution original would only cost time.
  final preview = await result.assets.first.thumbnailDataWithSize(
    const ThumbnailSize(1024, 1024),
    quality: 92,
  );
  if (preview == null) {
    if (context.mounted) showGlassToast(context, t.avatarFailed);
    return;
  }
  final ok = await ref.read(avatarProvider.notifier).setFromBytes(preview);
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

/// Convenience for the profile: the circle plus the tap that opens it.
class TappableAvatar extends ConsumerWidget {
  const TappableAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 72,
  });

  final String seed;
  final String label;
  final double size;

  static const String heroTag = 'profile-avatar';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(avatarProvider);
    return GestureDetector(
      onTap: () => Navigator.of(
        context,
        rootNavigator: true,
      ).push<void>(
        PageRouteBuilder<void>(
          opaque: false,
          barrierColor: Colors.transparent,
          transitionDuration: const Duration(milliseconds: 260),
          reverseTransitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (_, __, ___) => AvatarScreen(
            seed: seed,
            label: label,
            heroTag: heroTag,
          ),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      ),
      child: IdentityAvatar(
        seed: seed,
        label: label,
        size: size,
        heroTag: heroTag,
        imageBytes: bytes,
      ),
    );
  }
}
