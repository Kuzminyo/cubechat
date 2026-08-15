import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/domain/message_preview.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../data/chat_folders_controller.dart';
import '../data/user_chat_folders_controller.dart';
import 'chats_list_screen.dart' show chatsProvider, folderIcon, folderLabel;

/// Pick smart filters and manage real user folders.
class ChatFoldersScreen extends ConsumerWidget {
  const ChatFoldersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final chosen = ref.watch(chatFoldersControllerProvider);
    final controller = ref.read(chatFoldersControllerProvider.notifier);
    final userFolders = ref.watch(userChatFoldersControllerProvider);

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: BackButton(color: AppColors.textOnGlass),
          title: Text(
            t.chatsFoldersTitle,
            style: AppTypography.heading(size: 18),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
              child: Text(
                t.chatsFoldersHint,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            ),
            GlassCard(
              onTap: () => _createFolder(context, ref),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                children: [
                  Icon(Icons.create_new_folder_rounded,
                      color: AppColors.brandPrimary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      _folderText(context,
                          uk: '\u0421\u0442\u0432\u043e\u0440\u0438\u0442\u0438 \u043f\u0430\u043f\u043a\u0443',
                          en: 'Create folder'),
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(Icons.add_rounded, color: AppColors.brandPrimary),
                ],
              ),
            ),
            if (userFolders.isNotEmpty) ...[
              const SizedBox(height: 18),
              _SectionTitle(
                text: _folderText(context,
                    uk: '\u0412\u0430\u0448\u0456 \u043f\u0430\u043f\u043a\u0438',
                    en: 'Your folders'),
              ),
              for (final folder in userFolders) ...[
                GlassCard(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  child: Row(
                    children: [
                      Icon(Icons.folder_rounded,
                          color: AppColors.brandPrimary, size: 21),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              folder.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textOnGlass,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${folder.chatIds.length}',
                              style: TextStyle(
                                color: AppColors.textOnGlassDim,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit',
                        onPressed: () => _editFolder(context, ref, folder),
                        icon: Icon(Icons.tune_rounded,
                            color: AppColors.textOnGlassDim),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _deleteFolder(context, ref, folder),
                        icon:
                            Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
            const SizedBox(height: 18),
            _SectionTitle(
              text: _folderText(context,
                  uk: '\u0420\u043e\u0437\u0443\u043c\u043d\u0456 \u0444\u0456\u043b\u044c\u0442\u0440\u0438',
                  en: 'Smart filters'),
            ),
            for (final folder in ChatFolder.values) ...[
              GlassCard(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                onTap: () => controller.toggle(folder),
                child: Row(
                  children: [
                    Icon(folderIcon(folder),
                        size: 20, color: AppColors.brandPrimary),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        folderLabel(t, folder),
                        style: TextStyle(
                          color: AppColors.textOnGlass,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    Switch(
                      value: chosen.contains(folder),
                      activeThumbColor: AppColors.brandPrimary,
                      onChanged: (_) => controller.toggle(folder),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.textOnGlassDim,
            fontSize: 12,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

Future<void> _createFolder(BuildContext context, WidgetRef ref) async {
  final name = await _askFolderName(context);
  if (name == null) return;
  await ref.read(userChatFoldersControllerProvider.notifier).create(name);
}

Future<void> _editFolder(
  BuildContext context,
  WidgetRef ref,
  UserChatFolder folder,
) async {
  final chats = ref.read(chatsProvider);
  final selected = folder.chatIds.toSet();
  final renamed = TextEditingController(text: folder.name);
  final result = await showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (ctx, scroll) => DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.bgTop,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: AppColors.glassBorder),
          ),
          child: ListView(
            controller: scroll,
            padding: EdgeInsets.fromLTRB(
              18,
              16,
              18,
              24 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            children: [
              TextField(
                controller: renamed,
                style: TextStyle(color: AppColors.textOnGlass),
                decoration: InputDecoration(
                  labelText: _folderText(ctx,
                      uk: '\u041d\u0430\u0437\u0432\u0430 \u043f\u0430\u043f\u043a\u0438',
                      en: 'Folder name'),
                  labelStyle: TextStyle(color: AppColors.textOnGlassDim),
                ),
              ),
              const SizedBox(height: 16),
              for (final chat in chats)
                CheckboxListTile(
                  value: selected.contains(chat.id),
                  onChanged: (value) {
                    setState(() {
                      if (value ?? false) {
                        selected.add(chat.id);
                      } else {
                        selected.remove(chat.id);
                      }
                    });
                  },
                  activeColor: AppColors.brandPrimary,
                  checkColor: Colors.black,
                  title: Text(
                    chat.peerName,
                    style: TextStyle(color: AppColors.textOnGlass),
                  ),
                  subtitle: Text(
                    storedTextPreview(
                      chat.lastMessage,
                      AppLocalizations.of(ctx),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textOnGlassDim),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.of(ctx).pop(selected),
                child: Text(_folderText(ctx,
                    uk: '\u0417\u0431\u0435\u0440\u0435\u0433\u0442\u0438',
                    en: 'Save')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  final name = renamed.text.trim();
  renamed.dispose();
  if (result == null) return;
  final controller = ref.read(userChatFoldersControllerProvider.notifier);
  if (name.isNotEmpty && name != folder.name)
    await controller.rename(folder.id, name);
  await controller.setChats(folder.id, result);
}

Future<void> _deleteFolder(
  BuildContext context,
  WidgetRef ref,
  UserChatFolder folder,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      title: Text(
        _folderText(ctx,
            uk: '\u0412\u0438\u0434\u0430\u043b\u0438\u0442\u0438 \u043f\u0430\u043f\u043a\u0443?',
            en: 'Delete folder?'),
        style: TextStyle(color: AppColors.textOnGlass),
      ),
      content: Text(
        folder.name,
        style: TextStyle(color: AppColors.textOnGlassDim),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(_folderText(ctx,
              uk: '\u0421\u043a\u0430\u0441\u0443\u0432\u0430\u0442\u0438',
              en: 'Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            _folderText(ctx,
                uk: '\u0412\u0438\u0434\u0430\u043b\u0438\u0442\u0438',
                en: 'Delete'),
            style: TextStyle(color: AppColors.danger),
          ),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref
        .read(userChatFoldersControllerProvider.notifier)
        .delete(folder.id);
  }
}

Future<String?> _askFolderName(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      title: Text(
        _folderText(ctx,
            uk: '\u041d\u0430\u0437\u0432\u0430 \u043f\u0430\u043f\u043a\u0438',
            en: 'Folder name'),
        style: TextStyle(color: AppColors.textOnGlass),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: TextStyle(color: AppColors.textOnGlass),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(_folderText(ctx,
              uk: '\u0421\u043a\u0430\u0441\u0443\u0432\u0430\u0442\u0438',
              en: 'Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: Text(_folderText(ctx,
              uk: '\u0421\u0442\u0432\u043e\u0440\u0438\u0442\u0438',
              en: 'Create')),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.trim().isEmpty) return null;
  return result.trim();
}

String _folderText(
  BuildContext context, {
  required String uk,
  required String en,
}) =>
    Localizations.localeOf(context).languageCode == 'uk' ? uk : en;
