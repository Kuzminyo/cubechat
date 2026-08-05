import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/conversation_settings_controller.dart';
import 'widgets/chat_wallpaper_layer.dart';
import 'widgets/media_picker_sheet.dart';

/// Choose what one conversation is drawn on.
///
/// Local and cosmetic — nothing here is transmitted, so both people in a chat
/// can pick differently and neither ever knows.
class ChatWallpaperScreen extends ConsumerWidget {
  const ChatWallpaperScreen({super.key, required this.chatId});

  final String chatId;

  Future<void> _pickImage(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    final result = await showGlassSheet<MediaPickerResult>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const MediaPickerSheet(allowFiles: false),
    );
    if (result is! MediaPickerAssets || result.assets.isEmpty) return;

    // Sized for a phone screen rather than the original: a wallpaper is drawn
    // behind a conversation, and a 12-megapixel backdrop is decoded on every
    // rebuild for detail nobody can see through the scrim.
    final bytes = await result.assets.first.thumbnailDataWithSize(
      const ThumbnailSize(1440, 2560),
      quality: 88,
    );
    if (bytes == null) {
      if (context.mounted) showGlassToast(context, t.avatarFailed);
      return;
    }
    // Copied into app storage: the picker's own file is temporary, and a
    // wallpaper pointing at a collected path is a chat that loses its
    // background on the next launch for no visible reason.
    try {
      final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}'
        '${Platform.pathSeparator}cubechat-wallpaper',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      final safeId = chatId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File('${dir.path}${Platform.pathSeparator}$safeId.jpg');
      await file.writeAsBytes(bytes);
      final current = ref
          .read(conversationSettingsControllerProvider.notifier)
          .forChat(chatId)
          .wallpaper;
      await ref
          .read(conversationSettingsControllerProvider.notifier)
          .setWallpaper(
            chatId,
            ChatWallpaper(imagePath: file.path, dim: current.dim),
          );
    } catch (e) {
      if (context.mounted) {
        showGlassToast(context, '$e', tone: ToastTone.danger);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final settings = ref.watch(conversationSettingsControllerProvider);
    final wallpaper = settings[chatId]?.wallpaper ?? ChatWallpaper.none;
    final controller =
        ref.read(conversationSettingsControllerProvider.notifier);

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: AppColors.textOnGlass,
          title: Text(t.chatWallpaperTitle),
          actions: [
            if (wallpaper.isSet)
              TextButton(
                onPressed: () =>
                    controller.setWallpaper(chatId, ChatWallpaper.none),
                child: Text(
                  t.chatWallpaperClear,
                  style: TextStyle(color: AppColors.warning),
                ),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            for (var i = 0; i < ChatWallpaper.presets.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _WallpaperOption(
                  selected: wallpaper.presetIndex == i,
                  preview: ChatWallpaperPaint(
                    wallpaper:
                        ChatWallpaper(presetIndex: i, dim: wallpaper.dim),
                  ),
                  onTap: () => controller.setWallpaper(
                    chatId,
                    ChatWallpaper(presetIndex: i, dim: wallpaper.dim),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            _WallpaperOption(
              selected: wallpaper.imagePath != null,
              preview: wallpaper.imagePath != null
                  ? ChatWallpaperPaint(wallpaper: wallpaper)
                  : Center(
                      child: Icon(
                        Icons.add_photo_alternate_outlined,
                        color: AppColors.textOnGlassDim,
                      ),
                    ),
              onTap: () => _pickImage(context, ref),
            ),
            if (wallpaper.isSet) ...[
              const SizedBox(height: 20),
              Text(
                t.chatWallpaperDim,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
              ),
              Slider(
                value: wallpaper.dim,
                activeColor: AppColors.brandPrimary,
                onChanged: (value) => controller.setWallpaper(
                  chatId,
                  wallpaper.copyWith(dim: value),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WallpaperOption extends StatelessWidget {
  const _WallpaperOption({
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final bool selected;
  final Widget preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 96,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.brandPrimary : AppColors.glass(0.15),
            width: selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: preview,
        ),
      ),
    );
  }
}
