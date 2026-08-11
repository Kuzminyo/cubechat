import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/anon_name.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/shared_contact.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/identity_avatar.dart';
import 'widgets/peer_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/conversation_settings_controller.dart';
import '../../chat/data/drafts_controller.dart';
import '../../chat/presentation/widgets/auto_delete_picker.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/data/pinned_controller.dart';
import '../../chat/models/message.dart';
import '../../chats/data/favorites_controller.dart';
import '../../chats/models/chat.dart';
import '../../chats/presentation/chats_list_screen.dart';
import '../../profile/data/privacy_settings_controller.dart';
import '../data/contact_aliases_controller.dart';
import '../data/known_peers_controller.dart';
import '../data/peer_avatars_controller.dart';
import '../models/known_peer.dart';

class ContactProfileScreen extends ConsumerWidget {
  const ContactProfileScreen({
    super.key,
    required this.peerPubkeyHex,
    required this.peerLabel,
  });

  final String peerPubkeyHex;
  final String peerLabel;

  String _chatRoute() =>
      '/chat/' +
      Uri.encodeComponent(peerPubkeyHex) +
      '?name=' +
      Uri.encodeQueryComponent(peerLabel);

  String _verifyRoute() =>
      '/verify/' +
      Uri.encodeComponent(peerPubkeyHex) +
      '?name=' +
      Uri.encodeQueryComponent(peerLabel);

  String _contentRoute(int tab) =>
      '/person/' +
      Uri.encodeComponent(peerPubkeyHex) +
      '/content?name=' +
      Uri.encodeQueryComponent(peerLabel) +
      '&tab=$tab';

  Future<void> _setMuted(WidgetRef ref, KnownPeer? peer) => ref
      .read(knownPeersControllerProvider.notifier)
      .setMuted(peerPubkeyHex, !(peer?.isMuted ?? false));

  Future<void> _setBlocked(WidgetRef ref, KnownPeer? peer) => ref
      .read(knownPeersControllerProvider.notifier)
      .setBlocked(peerPubkeyHex, !(peer?.isBlocked ?? false));

  Future<void> _copyId(BuildContext context) async {
    final t = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: peerPubkeyHex));
    if (!context.mounted) return;
    showGlassToast(
      context,
      t.contactProfileIdCopied,
      icon: Icons.content_copy_rounded,
      tone: ToastTone.success,
    );
  }

  /// Rename a contact locally.
  ///
  /// Purely on this device: nothing goes on the wire, and a shared contact
  /// card still carries the name they chose for themselves. Clearing the box
  /// goes back to whatever they broadcast.
  Future<void> _renameContact(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    final aliases = ref.read(contactAliasesControllerProvider.notifier);
    await aliases.loaded;
    if (!context.mounted) return;
    final controller = TextEditingController(text: aliases.forPeer(peerPubkeyHex) ?? '');
    final chosen = await showGlassSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.viewInsetsOf(sheetContext).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.contactAliasAction,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                t.contactAliasHint,
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: kContactAliasMaxLength,
                style: TextStyle(color: AppColors.textOnGlass),
                decoration: InputDecoration(
                  hintText: displayNameForPeer('', peerPubkeyHex),
                  hintStyle: TextStyle(color: AppColors.textOnGlassDim),
                  border: const OutlineInputBorder(),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.black,
                ),
                onPressed: () =>
                    Navigator.of(sheetContext).pop(controller.text),
                child: Text(t.profileNicknameSave),
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();
    if (chosen == null) return; // backed out, leave the name alone
    await aliases.setAlias(peerPubkeyHex, chosen);
  }

  // contact profile actions
  String _autoDeleteLabel(AppLocalizations t, ChatAutoDelete period) =>
      formatAutoDelete(t, period);

  Future<void> _chooseAutoDelete(
    BuildContext context,
    WidgetRef ref,
    ChatAutoDelete current,
  ) async {
    final t = AppLocalizations.of(context);
    final chosen = await showAutoDeletePicker(context, current);
    if (chosen == null || chosen == current) return;
    await ref
        .read(conversationSettingsControllerProvider.notifier)
        .setAutoDelete(peerPubkeyHex, chosen);
    if (!context.mounted) return;
    showGlassToast(
      context,
      t.contactProfileAutoDeleteUpdated(_autoDeleteLabel(t, chosen)),
      icon: Icons.auto_delete_outlined,
      tone: ToastTone.success,
    );
  }

  Future<void> _shareContact(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    final targets = ref
        .read(chatsProvider)
        .where((chat) => chat.id != peerPubkeyHex)
        .toList();
    final chosen = await showDialog<Chat>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: AppColors.glass(0.15)),
        ),
        title: Text(
          t.contactProfileShareTitle,
          style: TextStyle(color: AppColors.textOnGlass),
        ),
        children: [
          if (targets.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              child: Text(
                t.contactProfileShareEmpty,
                style: TextStyle(color: AppColors.textOnGlassDim),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.42,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final chat in targets)
                      SimpleDialogOption(
                        onPressed: () => Navigator.of(dialogContext).pop(chat),
                        child: Row(
                          children: [
                            Icon(
                              chat.isChannel
                                  ? Icons.campaign_rounded
                                  : Icons.person_outline_rounded,
                              color: AppColors.textOnGlassDim,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                chat.peerName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: AppColors.textOnGlass),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              t.cancel,
              style: TextStyle(color: AppColors.textOnGlassDim),
            ),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    final payload = SharedContact(
      pubkeyHex: peerPubkeyHex,
      displayName: peerLabel,
    ).encode();
    final messaging = ref.read(messagingServiceProvider);
    if (chosen.isChannel) {
      await messaging.sendChannelText(chosen.id, payload);
    } else {
      await messaging.sendText(chosen.id, payload);
    }
    if (!context.mounted) return;
    showGlassToast(
      context,
      t.contactProfileShareSent(chosen.peerName),
      icon: Icons.person_add_alt_1_rounded,
      tone: ToastTone.success,
    );
  }

  Future<void> _deleteContact(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: AppColors.glass(0.15)),
        ),
        title: Text(
          t.contactProfileDeleteTitle,
          style: TextStyle(color: AppColors.textOnGlass),
        ),
        content: Text(
          t.contactProfileDeleteMessage(peerLabel),
          style: TextStyle(color: AppColors.textOnGlassDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              t.contactProfileDelete,
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(knownPeersControllerProvider.notifier).forget(peerPubkeyHex);
    await ref
        .read(peerAvatarsControllerProvider.notifier)
        .forget(peerPubkeyHex);
    await ref
        .read(conversationSettingsControllerProvider.notifier)
        .forget(peerPubkeyHex);
    await ref.read(favoritesControllerProvider.notifier).forget(peerPubkeyHex);
    await ref.read(pinnedControllerProvider.notifier).forget(peerPubkeyHex);
    await ref.read(draftsControllerProvider.notifier).clear(peerPubkeyHex);
    if (context.mounted) Navigator.of(context).maybePop();
  }

  Widget _actionsPanel(
    BuildContext context,
    WidgetRef ref,
    KnownPeer? peer,
    VoidCallback close,
  ) {
    final t = AppLocalizations.of(context);
    final conversationSettings =
        ref.watch(conversationSettingsControllerProvider)[peerPubkeyHex] ??
            ConversationSettings.initial;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: close,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.46),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: FractionallySizedBox(
              widthFactor: 0.82,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 48, 8, 12),
                child: GlassCard(
                  strong: true,
                  borderRadius: 28,
                  // Floats over the scrolled profile, not the aurora — here
                  // there is real detail behind the panel worth softening.
                  blur: true,
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                t.contactProfileActions,
                                style: AppTypography.heading(size: 20),
                              ),
                            ),
                            IconButton(
                              onPressed: close,
                              icon: const Icon(Icons.close_rounded),
                              color: AppColors.textOnGlassDim,
                            ),
                          ],
                        ),
                      ),
                      _ActionTile(
                        icon: Icons.drive_file_rename_outline,
                        label: t.contactAliasAction,
                        // The name they broadcast, shown underneath, so it is
                        // clear the rename is yours and theirs is untouched.
                        subtitle: displayNameForPeer(
                          peer?.displayName ?? '',
                          peerPubkeyHex,
                        ),
                        onTap: () {
                          close();
                          _renameContact(context, ref);
                        },
                      ),
                      _ActionTile(
                        icon: Icons.auto_delete_outlined,
                        label: t.contactProfileAutoDelete,
                        subtitle: _autoDeleteLabel(
                          t,
                          conversationSettings.autoDelete,
                        ),
                        onTap: () {
                          close();
                          _chooseAutoDelete(
                            context,
                            ref,
                            conversationSettings.autoDelete,
                          );
                        },
                      ),
                      _ActionTile(
                        icon: Icons.wallpaper_outlined,
                        label: t.chatWallpaperTitle,
                        onTap: () {
                          close();
                          context.push(
                            '/wallpaper/${Uri.encodeComponent(peerPubkeyHex)}',
                          );
                        },
                      ),
                      _ActionTile(
                        icon: Icons.person_add_alt_1_outlined,
                        label: t.contactProfileShare,
                        onTap: () {
                          close();
                          _shareContact(context, ref);
                        },
                      ),
                      _ActionTile(
                        icon: conversationSettings.restrictCopying
                            ? Icons.content_copy_rounded
                            : Icons.layers_clear_rounded,
                        label: conversationSettings.restrictCopying
                            ? t.contactProfileAllowCopying
                            : t.contactProfileRestrictCopying,
                        // Says what the conversation is actually doing, which
                        // is not always what this switch says: the peer may
                        // have asked for the same thing, and then turning ours
                        // off changes nothing here. Better to read that from
                        // the row than to discover it at an absent Forward.
                        subtitle: conversationSettings.copyingRestricted
                            ? (conversationSettings.restrictCopying
                                ? t.contactProfileCopyingRestricted
                                : t.contactProfileCopyingRestrictedByPeer)
                            : null,
                        onTap: () async {
                          close();
                          final restricted =
                              !conversationSettings.restrictCopying;
                          await ref
                              .read(conversationSettingsControllerProvider
                                  .notifier)
                              .setRestrictCopying(
                                peerPubkeyHex,
                                restricted,
                              );
                          // The half that matters: the other phone is the one
                          // that could forward this conversation on, and it
                          // cannot honour a switch it never heard about.
                          unawaited(
                            ref
                                .read(messagingServiceProvider)
                                .announceCopyRestriction(
                                  peerPubkeyHex,
                                  restricted: restricted,
                                  force: true,
                                ),
                          );
                          if (!context.mounted) return;
                          showGlassToast(
                            context,
                            restricted
                                ? t.contactProfileCopyingRestricted
                                : t.contactProfileCopyingAllowed,
                            icon: restricted
                                ? Icons.layers_clear_rounded
                                : Icons.content_copy_rounded,
                            tone: ToastTone.success,
                          );
                        },
                      ),
                      _ActionTile(
                        icon: Icons.person_remove_outlined,
                        label: t.contactProfileDelete,
                        onTap: () {
                          close();
                          _deleteContact(context, ref);
                        },
                      ),
                      const Divider(height: 1, color: Color(0x26FFFFFF)),
                      _ActionTile(
                        icon: Icons.block_rounded,
                        label: peer?.isBlocked == true
                            ? t.peerUnblock
                            : t.peerBlock,
                        tone: AppColors.danger,
                        onTap: () {
                          close();
                          _setBlocked(ref, peer);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final peer = ref.watch(knownPeersControllerProvider)[peerPubkeyHex];
    final messages = ref.watch(messagesControllerProvider)[peerPubkeyHex] ??
        const <Message>[];
    final mediaCount =
        messages.where((message) => message.kind == MessageKind.image).length;
    final voiceCount =
        messages.where((message) => message.kind == MessageKind.audio).length;
    final fileCount =
        messages.where((message) => message.kind == MessageKind.file).length;
    final chats = ref.watch(chatsProvider);
    Chat? contact;
    for (final chat in chats) {
      if (!chat.isChannel && chat.peerId == peerPubkeyHex) {
        contact = chat;
        break;
      }
    }

    // Hiding last-seen withholds *times*, in both directions: no time out, no
    // times in. What somebody is doing right now is not a time, so being
    // online or reachable is still reported \u2014 it used to be suppressed too,
    // which left this screen saying nothing about a person who was plainly
    // there.
    final presenceShared = ref.watch(privacySettingsProvider).shareLastSeen;
    final active =
        contact?.isOnline == true || contact?.isReachableViaMesh == true;
    final String status;
    if (contact?.isOnline == true) {
      status = t.presenceOnline;
    } else if (contact?.isReachableViaMesh == true) {
      status = t.chatsStatusViaMesh;
    } else if (!presenceShared) {
      status = t.presenceRecently;
    } else if (peer == null) {
      status = t.presenceOffline;
    } else {
      status = [
        t.presenceOffline,
        formatChatListTime(context, peer.lastSeen),
      ].join(' \u00B7 ');
    }
    final heroHeight =
        (MediaQuery.sizeOf(context).height * 0.61).clamp(430.0, 560.0);

    var actionsOpen = false;
    return StatefulBuilder(
      builder: (context, setMenuState) {
        void closeActions() {
          setMenuState(() => actionsOpen = false);
        }

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _ProfileHero(
                      height: heroHeight,
                      peerId: peerPubkeyHex,
                      label: peerLabel,
                      status: status,
                      statusColor:
                          active ? AppColors.online : AppColors.textOnGlassDim,
                      online: contact?.isOnline ?? false,
                      muted: peer?.isMuted ?? false,
                      blocked: peer?.isBlocked ?? false,
                      onBack: () => Navigator.of(context).maybePop(),
                      onMore: () => setMenuState(() => actionsOpen = true),
                      onChat: () => context.push(_chatRoute()),
                      onMute: () => _setMuted(ref, peer),
                      onVerify: () => context.push(_verifyRoute()),
                      onBlock: () => _setBlocked(ref, peer),
                      chatLabel: t.contactProfileChat,
                      muteLabel:
                          peer?.isMuted == true ? t.peerUnmute : t.peerMute,
                      verifyLabel: t.contactProfileVerify,
                      blockLabel:
                          peer?.isBlocked == true ? t.peerUnblock : t.peerBlock,
                      moreTooltip: t.contactProfileActions,
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 140),
                    sliver: SliverList.list(
                      children: [
                        _InfoCard(
                          icon: Icons.key_rounded,
                          title: t.contactProfileId,
                          value: peerPubkeyHex,
                          onCopy: () => _copyId(context),
                        ),
                        const SizedBox(height: 12),
                        GlassCard(
                          strong: true,
                          child: Row(
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: AppColors.brandPrimary
                                      .withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: Icon(
                                  peer?.isVerified == true
                                      ? Icons.verified_rounded
                                      : Icons.shield_outlined,
                                  color: AppColors.brandPrimary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t.contactProfileSecurity,
                                      style: TextStyle(
                                        color: AppColors.textOnGlass,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      peer?.isVerified == true
                                          ? t.verifyAlreadyDone
                                          : t.contactProfileVerifyHint,
                                      style: TextStyle(
                                        color: AppColors.textOnGlassDim,
                                        fontSize: 12,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: () => context.push(_verifyRoute()),
                                tooltip: t.contactProfileVerify,
                                icon: Icon(
                                  Icons.chevron_right_rounded,
                                  color: AppColors.textOnGlassDim,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _SharedContentCard(
                          mediaLabel: t.contactProfileMedia,
                          voiceLabel: t.contactProfileVoiceMessages,
                          fileLabel: t.contactProfileFiles,
                          mediaCount: mediaCount,
                          voiceCount: voiceCount,
                          fileCount: fileCount,
                          onMedia: () => context.push(_contentRoute(0)),
                          onVoice: () => context.push(_contentRoute(1)),
                          onFiles: () => context.push(_contentRoute(2)),
                        ),
                        if (peer?.isBlocked == true) ...[
                          const SizedBox(height: 12),
                          GlassCard(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.block_rounded,
                                  color: AppColors.danger,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    t.peerBlockedNote,
                                    style: TextStyle(
                                      color: AppColors.textOnGlassDim,
                                      fontSize: 13,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (actionsOpen)
                Positioned.fill(
                  child: _actionsPanel(context, ref, peer, closeActions),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ProfileHero extends ConsumerWidget {
  const _ProfileHero({
    required this.height,
    required this.peerId,
    required this.label,
    required this.status,
    required this.statusColor,
    required this.online,
    required this.muted,
    required this.blocked,
    required this.onBack,
    required this.onMore,
    required this.onChat,
    required this.onMute,
    required this.onVerify,
    required this.onBlock,
    required this.chatLabel,
    required this.muteLabel,
    required this.verifyLabel,
    required this.blockLabel,
    required this.moreTooltip,
  });

  final double height;
  final String peerId;
  final String label;
  final String status;
  final Color statusColor;
  final bool online;
  final bool muted;
  final bool blocked;
  final VoidCallback onBack;
  final VoidCallback onMore;
  final VoidCallback onChat;
  final VoidCallback onMute;
  final VoidCallback onVerify;
  final VoidCallback onBlock;
  final String chatLabel;
  final String muteLabel;
  final String verifyLabel;
  final String blockLabel;
  final String moreTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = IdentityAvatar.paletteFor(peerId);
    final avatarSize =
        (MediaQuery.sizeOf(context).width * 0.42).clamp(132.0, 176.0);
    // Their picture, full-bleed across the header — the same thing your own
    // profile does with yours. A round portrait floating on a gradient was the
    // one place in the app where somebody's face was shown as a token rather
    // than as a photograph, and the round one below it is still there for the
    // identity it carries (the online dot, the letters when there is no photo).
    final photo = ref.watch(peerAvatarsControllerProvider)[peerId];
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (photo != null)
            Image.memory(
              photo,
              fit: BoxFit.cover,
              // The bytes are full HD so the header stays sharp; decoding them
              // at the size actually drawn keeps the cache honest.
              cacheWidth: (MediaQuery.sizeOf(context).width *
                      MediaQuery.devicePixelRatioOf(context))
                  .round(),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    palette.first.withValues(alpha: 0.78),
                    AppColors.bgBottom,
                    AppColors.bgDeep,
                  ],
                  stops: const [0, 0.58, 1],
                ),
              ),
            ),
          // Only when there is no photograph. With one, the header *is* their
          // picture — a circle holding the same image on top of it is the same
          // face twice, at two sizes, which is what it looked like.
          if (photo == null)
            Align(
              alignment: const Alignment(0, -0.34),
              child: PeerAvatar(
                peerId: peerId,
                label: label,
                size: avatarSize,
                online: online,
                heroTag: 'contact-avatar-' + peerId,
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0x00000000),
                  const Color(0x33000000),
                  // The same frozen emerald the profile header carried: this
                  // one darkened a contact's photo to a green that belonged to
                  // no palette in use.
                  AppColors.bgDeep.withValues(alpha: 0.90),
                ],
                stops: const [0.30, 0.62, 1],
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.topCenter,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoundButton(
                      icon: Icons.arrow_back_rounded,
                      onTap: onBack,
                    ),
                    _RoundButton(
                      icon: Icons.more_vert_rounded,
                      tooltip: moreTooltip,
                      onTap: onMore,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 108,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.display(size: 31),
                ),
                const SizedBox(height: 7),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: GlassCard(
              strong: true,
              padding: EdgeInsets.zero,
              borderRadius: 26,
              child: SizedBox(
                height: 84,
                child: Row(
                  children: [
                    _QuickAction(
                      icon: Icons.chat_bubble_rounded,
                      label: chatLabel,
                      onTap: onChat,
                    ),
                    _QuickAction(
                      icon: muted
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_off_rounded,
                      label: muteLabel,
                      onTap: onMute,
                    ),
                    _QuickAction(
                      icon: Icons.verified_user_outlined,
                      label: verifyLabel,
                      onTap: onVerify,
                    ),
                    _QuickAction(
                      icon: blocked ? Icons.lock_open_rounded : Icons.block,
                      label: blockLabel,
                      tone: blocked ? AppColors.brandPrimary : AppColors.danger,
                      onTap: onBlock,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.34),
        shape: const CircleBorder(),
        child: IconButton(
          onPressed: onTap,
          tooltip: tooltip,
          icon: Icon(icon, color: AppColors.textOnGlass, size: 25),
        ),
      );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tone = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color tone;

  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: tone, size: 25),
                const SizedBox(height: 7),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: tone,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.tone = Colors.white,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final Color tone;

  @override
  Widget build(BuildContext context) => ListTile(
        minLeadingWidth: 32,
        leading: Icon(icon, color: tone, size: 24),
        title: Text(
          label,
          style: TextStyle(
            color: tone,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 11,
                ),
              ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: tone.withValues(alpha: 0.52),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onTap: onTap,
      );
}

class _SharedContentCard extends StatelessWidget {
  const _SharedContentCard({
    required this.mediaLabel,
    required this.voiceLabel,
    required this.fileLabel,
    required this.mediaCount,
    required this.voiceCount,
    required this.fileCount,
    required this.onMedia,
    required this.onVoice,
    required this.onFiles,
  });

  final String mediaLabel;
  final String voiceLabel;
  final String fileLabel;
  final int mediaCount;
  final int voiceCount;
  final int fileCount;
  final VoidCallback onMedia;
  final VoidCallback onVoice;
  final VoidCallback onFiles;

  @override
  Widget build(BuildContext context) => GlassCard(
        strong: true,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            _ContentRow(
              icon: Icons.photo_library_outlined,
              label: mediaLabel,
              count: mediaCount,
              onTap: onMedia,
            ),
            const Divider(height: 1, color: Color(0x26FFFFFF)),
            _ContentRow(
              icon: Icons.mic_none_rounded,
              label: voiceLabel,
              count: voiceCount,
              onTap: onVoice,
            ),
            const Divider(height: 1, color: Color(0x26FFFFFF)),
            _ContentRow(
              icon: Icons.folder_outlined,
              label: fileLabel,
              count: fileCount,
              onTap: onFiles,
            ),
          ],
        ),
      );
}

class _ContentRow extends StatelessWidget {
  const _ContentRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.brandPrimary.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: AppColors.brandPrimary, size: 22),
        ),
        title: Text(
          label,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$count',
              style: TextStyle(
                color: AppColors.textOnGlassDim,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textOnGlassDim,
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        onTap: onTap,
      );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.onCopy,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => GlassCard(
        strong: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.brandPrimary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.mono(
                      size: 13,
                      color: AppColors.textOnGlass,
                      weight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onCopy,
              icon: Icon(
                Icons.copy_rounded,
                color: AppColors.textOnGlassDim,
                size: 20,
              ),
            ),
          ],
        ),
      );
}
