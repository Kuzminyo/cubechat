import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../chat/presentation/chat_media_gallery_screen.dart';
import '../../chat/presentation/widgets/voice_bubble.dart';

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

    return DefaultTabController(
      length: 2,
      initialIndex: initialTab.clamp(0, 1),
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
            tabs: [
              Tab(text: t.contactProfileMedia),
              Tab(text: t.contactProfileVoiceMessages),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _MediaGrid(
              chatId: chatId,
              images: images,
              emptyLabel: t.contactProfileNoMedia,
            ),
            _VoiceList(
              voices: voices,
              emptyLabel: t.contactProfileNoVoiceMessages,
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
    required this.emptyLabel,
  });

  final String chatId;
  final List<Message> images;
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
  const _VoiceList({required this.voices, required this.emptyLabel});

  final List<Message> voices;
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
      itemBuilder: (_, index) => GlassCard(
        strong: true,
        child: VoiceBubble(message: voices[index]),
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
