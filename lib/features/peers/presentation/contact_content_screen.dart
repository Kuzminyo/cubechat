import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../chat/presentation/chat_media_gallery_screen.dart';
import '../../chat/presentation/widgets/file_bubble.dart';
import '../../chat/presentation/widgets/voice_bubble.dart';

@visibleForTesting
String routeForMessageInChat({
  required String chatId,
  required String contactName,
  required String messageId,
}) {
  final query = Uri(
    queryParameters: {'name': contactName, 'message': messageId},
  ).query;
  return '/chat/${Uri.encodeComponent(chatId)}?$query';
}

class ContactContentScreen extends ConsumerWidget {
  const ContactContentScreen({
    super.key,
    required this.chatId,
    required this.contactName,
    this.initialTab = 0,
  });

  final String chatId;
  final String contactName;
  final int initialTab;
  Future<void> _showMessageActions(
    BuildContext context,
    Message message,
  ) async {
    final t = AppLocalizations.of(context);
    final openInChat = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlassCard(
          strong: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ListTile(
            leading: Icon(
              Icons.chat_bubble_outline_rounded,
              color: AppColors.brandPrimary,
            ),
            title: Text(
              t.contactProfileViewInChat,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
        ),
      ),
    );
    if (openInChat != true || !context.mounted) return;
    context.go(routeForMessageInChat(
      chatId: chatId,
      contactName: contactName,
      messageId: message.id,
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final messages =
        ref.watch(messagesControllerProvider)[chatId] ?? const <Message>[];
    final images = messages
        .where((message) =>
            message.kind == MessageKind.image && message.imagePath != null)
        .toList()
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
    final voices = messages
        .where((message) =>
            message.kind == MessageKind.audio && message.audioPath != null)
        .toList()
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
    final files = messages
        .where((message) =>
            message.kind == MessageKind.file && message.filePath != null)
        .toList()
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));

    return DefaultTabController(
      length: 3,
      initialIndex: initialTab.clamp(0, 2),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: BackButton(color: AppColors.textOnGlass),
          title: Text(
            contactName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.heading(size: 18),
          ),
          bottom: TabBar(
            indicatorColor: AppColors.brandPrimary,
            labelColor: AppColors.brandPrimary,
            unselectedLabelColor: AppColors.textOnGlassDim,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: t.contactProfileMedia),
              Tab(text: t.contactProfileVoiceMessages),
              Tab(text: t.contactProfileFiles),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _MediaGrid(
              chatId: chatId,
              images: images,
              onLongPress: (message) => _showMessageActions(context, message),
              emptyLabel: t.contactProfileNoMedia,
            ),
            _VoiceList(
              voices: voices,
              onLongPress: (message) => _showMessageActions(context, message),
              emptyLabel: t.contactProfileNoVoiceMessages,
            ),
            _FileList(
              files: files,
              onLongPress: (message) => _showMessageActions(context, message),
              emptyLabel: t.contactProfileNoFiles,
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({
    required this.chatId,
    required this.images,
    required this.onLongPress,
    required this.emptyLabel,
  });

  final String chatId;
  final List<Message> images;
  final ValueChanged<Message> onLongPress;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return _EmptyContent(
          icon: Icons.photo_library_outlined, label: emptyLabel);
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 32),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: images.length,
      itemBuilder: (context, index) {
        final message = images[index];
        return Material(
          color: AppColors.glassFill,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onLongPress: () => onLongPress(message),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatMediaGalleryScreen(
                  chatId: chatId,
                  initialMessageId: message.id,
                ),
              ),
            ),
            child: Hero(
              tag: 'image-${message.id}',
              child: Image.file(
                File(message.imagePath!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VoiceList extends StatelessWidget {
  const _VoiceList({
    required this.voices,
    required this.onLongPress,
    required this.emptyLabel,
  });

  final List<Message> voices;
  final ValueChanged<Message> onLongPress;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (voices.isEmpty) {
      return _EmptyContent(icon: Icons.mic_none_rounded, label: emptyLabel);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: voices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: () => onLongPress(voices[index]),
        child: GlassCard(
          strong: true,
          child: VoiceBubble(message: voices[index]),
        ),
      ),
    );
  }
}

/// Everything that was sent as a file, newest first.
///
/// Reuses [FileBubble] rather than re-describing a file: the row already knows
/// how to name it, size it, pick an icon from the extension, and hand it to the
/// system on a tap — and a second implementation would drift from that one.
class _FileList extends StatelessWidget {
  const _FileList({
    required this.files,
    required this.onLongPress,
    required this.emptyLabel,
  });

  final List<Message> files;
  final ValueChanged<Message> onLongPress;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return _EmptyContent(
          icon: Icons.insert_drive_file_outlined, label: emptyLabel);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) => FileBubble(
        message: files[index],
        onLongPress: () => onLongPress(files[index]),
      ),
    );
  }
}

class _EmptyContent extends StatelessWidget {
  const _EmptyContent({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textOnGlassFaint),
            const SizedBox(height: 12),
            Text(
              label,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 14),
            ),
          ],
        ),
      );
}
