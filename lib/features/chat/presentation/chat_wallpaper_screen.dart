import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/conversation_settings_controller.dart';
import 'widgets/chat_wallpaper_layer.dart';
import 'widgets/media_picker_sheet.dart';

/// Choose what one conversation is drawn on.
///
/// Presets can stay local or be sent as a tiny encrypted control frame so the
/// other side/channel sees the same backdrop. Custom photos stay local until
/// they get their own chunked wallpaper transfer path.
class ChatWallpaperScreen extends ConsumerWidget {
  const ChatWallpaperScreen({super.key, required this.chatId});

  final String chatId;

  Future<void> _pickImage(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    final scope = await _askApplyScope(context, allowShared: false);
    if (!context.mounted || scope == null) return;
    if (scope == _WallpaperApplyScope.shared) {
      showGlassToast(
        context,
        _wallpaperText(
          context,
          uk: 'Фото-шпалери поки можна ставити тільки локально',
          en: 'Photo wallpapers are local-only for now',
        ),
        tone: ToastTone.neutral,
      );
      return;
    }
    final result = await showGlassSheet<MediaPickerResult>(
      context: context,
      useRootNavigator: true,
      builder: (_) =>
          const MediaPickerSheet(allowFiles: false, allowCaption: false),
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
                onPressed: () => _applyWallpaper(
                  context,
                  ref,
                  controller,
                  ChatWallpaper.none,
                ),
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
                  onTap: () => _applyWallpaper(
                    context,
                    ref,
                    controller,
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

enum _WallpaperApplyScope { local, shared }

extension on ChatWallpaperScreen {
  Future<void> _applyWallpaper(
    BuildContext context,
    WidgetRef ref,
    ConversationSettingsController controller,
    ChatWallpaper wallpaper,
  ) async {
    final scope = await _askApplyScope(
      context,
      allowShared: wallpaper.imagePath == null,
    );
    if (!context.mounted || scope == null) return;
    if (scope == _WallpaperApplyScope.local) {
      await controller.setWallpaper(chatId, wallpaper);
      return;
    }
    if (wallpaper.imagePath != null) {
      showGlassToast(
        context,
        _wallpaperText(
          context,
          uk: 'Фото-шпалери поки можна ставити тільки локально',
          en: 'Photo wallpapers are local-only for now',
        ),
        tone: ToastTone.neutral,
      );
      return;
    }
    try {
      final delivered = await ref
          .read(messagingServiceProvider)
          .sendSharedWallpaper(chatId, wallpaper);
      if (context.mounted && !delivered) {
        showGlassToast(
          context,
          _wallpaperText(
            context,
            uk: 'Збережено тут. Зараз немає маршруту до співрозмовника',
            en: 'Saved here. There is no route to the peer right now',
          ),
          tone: ToastTone.neutral,
        );
      }
    } catch (e) {
      if (context.mounted) {
        showGlassToast(context, '$e', tone: ToastTone.danger);
      }
    }
  }

  Future<_WallpaperApplyScope?> _askApplyScope(
    BuildContext context, {
    bool allowShared = true,
  }) async {
    final isChannel = chatId.startsWith('#');
    final title = _wallpaperText(
      context,
      uk: 'Хто буде бачити ці шпалери?',
      en: 'Who should see this wallpaper?',
    );
    final sharedLabel = isChannel
        ? _wallpaperText(
            context,
            uk: 'Весь канал',
            en: 'Whole channel',
          )
        : _wallpaperText(
            context,
            uk: 'Я і співрозмовник',
            en: 'Me and the other person',
          );
    final picked = await showGlassSheet<_WallpaperApplyScope>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              ListTile(
                leading: Icon(Icons.phone_iphone_rounded,
                    color: AppColors.brandPrimary),
                title: Text(
                  _wallpaperText(
                    context,
                    uk: 'Тільки у мене',
                    en: 'Only on my phone',
                  ),
                  style: TextStyle(color: AppColors.textOnGlass),
                ),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_WallpaperApplyScope.local),
              ),
              ListTile(
                enabled: allowShared,
                leading: Icon(
                  Icons.sync_rounded,
                  color: allowShared
                      ? AppColors.brandPrimary
                      : AppColors.textOnGlassFaint,
                ),
                title: Text(
                  sharedLabel,
                  style: TextStyle(
                    color: allowShared
                        ? AppColors.textOnGlass
                        : AppColors.textOnGlassDim,
                  ),
                ),
                subtitle: Text(
                  allowShared
                      ? _wallpaperText(
                          context,
                          uk: 'Надсилається зашифрованим службовим пакетом',
                          en: 'Sent as an encrypted control frame',
                        )
                      : _wallpaperText(
                          context,
                          uk: 'Фото поки лишається тільки на цьому телефоні',
                          en: 'Photos stay on this phone for now',
                        ),
                  style: TextStyle(color: AppColors.textOnGlassFaint),
                ),
                onTap: allowShared
                    ? () => Navigator.of(sheetContext)
                        .pop(_WallpaperApplyScope.shared)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
    return picked;
  }
}

String _wallpaperText(
  BuildContext context, {
  required String uk,
  required String en,
}) =>
    Localizations.localeOf(context).languageCode == 'uk' ? uk : en;

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
