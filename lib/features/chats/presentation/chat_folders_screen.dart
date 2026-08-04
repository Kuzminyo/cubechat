import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../data/chat_folders_controller.dart';
import 'chats_list_screen.dart' show folderIcon, folderLabel;

/// Pick which folders the chat list offers.
///
/// The list ships with none. These are cuts of the same list rather than places
/// chats are moved to — nothing has to be filed, and a chat leaves Unread by
/// being read — so switching one on costs nothing and switching it off loses
/// nothing.
class ChatFoldersScreen extends ConsumerWidget {
  const ChatFoldersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final chosen = ref.watch(chatFoldersControllerProvider);
    final controller = ref.read(chatFoldersControllerProvider.notifier);

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: BackButton(color: AppColors.textOnGlass),
          title: Text(t.chatsFoldersTitle, style: AppTypography.heading(size: 18)),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
              child: Text(
                t.chatsFoldersHint,
                style:
                    TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
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
