part of 'customize_screen.dart';

/// Chats & media: what a swipe does, what a message sends and what it costs.
/// The cards are the ones Customize carried; the circle's lens joins them from
/// the old privacy card, beside the circle's sound.
class ChatsSectionScreen extends ConsumerWidget {
  const ChatsSectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    // Circles are recorded with the camera; a computer has none to record
    // with, so their two settings would change nothing there.
    final circles = ref.watch(platformCapabilitiesProvider).camera;
    return SettingsSectionScaffold(
      title: t.sectionChats,
      children: [
        const _SwipeCard(),
        const SizedBox(height: 12),
        // Next to the swipe, because archiving is what the swipe does by
        // default and this decides whether the result is visible.
        const _ArchiveRowCard(),
        const SizedBox(height: 12),
        const _QuickReactionCard(),
        const SizedBox(height: 12),
        if (circles) ...const [
          _CircleAudioCard(),
          SizedBox(height: 12),
          GlassCard(child: CircleLensTile()),
          SizedBox(height: 12),
        ],
        // Beside the circle's sound: both are about what a message you
        // send costs, not about how the app looks.
        const _MediaQualityCard(),
        const SizedBox(height: 12),
        const _MediaDownloadCard(),
        const SizedBox(height: 12),
        const _TranscribeLanguageCard(),
      ],
    );
  }
}
