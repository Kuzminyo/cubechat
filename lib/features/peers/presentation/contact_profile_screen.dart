import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/anon_name.dart';
import '../../../core/routing/back_gesture.dart';
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
import '../../chat/presentation/widgets/auto_delete_picker.dart';
import '../../chat/presentation/widgets/emoji_picker_sheet.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../chats/models/chat.dart';
import '../../chats/presentation/chats_list_screen.dart';
import '../../chats/presentation/widgets/chat_picker_screen.dart';
import '../../profile/data/privacy_settings_controller.dart';
import '../data/contact_aliases_controller.dart';
import '../data/contact_tags_controller.dart';
import '../data/contact_removal.dart';
import '../data/known_peers_controller.dart';
import '../data/peer_avatars_controller.dart';
import '../data/presence_controller.dart';
import '../models/known_peer.dart';

class ContactProfileScreen extends ConsumerStatefulWidget {
  const ContactProfileScreen({
    super.key,
    required this.peerPubkeyHex,
    required this.peerLabel,
  });

  final String peerPubkeyHex;
  final String peerLabel;

  @override
  ConsumerState<ContactProfileScreen> createState() =>
      _ContactProfileScreenState();
}

/// The same header mechanic as your own profile: a face in the middle at rest,
/// swiped up into a full-bleed photograph.
///
/// Written here rather than shared with the profile cover because the two
/// headers hold different things — this one carries a back button, four quick
/// actions and somebody else's status — and a widget parameterised over both
/// would be a worse explanation of either.
class _ContactProfileScreenState extends ConsumerState<ContactProfileScreen>
    with SingleTickerProviderStateMixin {
  /// 0 = the face is a circle, 1 = it fills the header.
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 260),
  );

  /// How far the finger travels up the picture before it opens. The same
  /// number as the profile's, because it is the same gesture.
  static const double _dragToOpen = 48;

  /// How far past the top the list has to be pulled to do the same thing.
  /// Higher than the face's, because the bounce at the end of a flick lives
  /// here and must not count as a decision.
  static const double _pullToOpen = 64;

  /// The list's half of the gesture, so a thumb already at the top of the
  /// screen opens the picture the way it does in every other messenger.
  bool _onScroll(ScrollNotification n) {
    if (n is! ScrollUpdateNotification) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    final px = n.metrics.pixels;
    if (px <= -_pullToOpen) {
      if (_open.value < 1 && !_open.isAnimating) _open.forward();
    } else if (px > 24) {
      // Reading the settings puts the picture away; left open it would sit
      // under them and eat the screen.
      if (_open.value > 0 && !_open.isAnimating) _open.reverse();
    }
    return false;
  }

  double _dragOnFace = 0;

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  void _faceDragStart() => _dragOnFace = 0;

  void _faceDrag(DragUpdateDetails d) {
    _dragOnFace += d.delta.dy;
    if (_open.isAnimating) return;
    if (_dragOnFace <= -_dragToOpen && _open.value < 1) {
      _dragOnFace = 0;
      _open.forward();
    } else if (_dragOnFace >= _dragToOpen && _open.value > 0) {
      _dragOnFace = 0;
      _open.reverse();
    }
  }

  void _toggleFace() =>
      _open.status == AnimationStatus.completed || _open.value > 0.5
          ? _open.reverse()
          : _open.forward();

  String get peerPubkeyHex => widget.peerPubkeyHex;
  String get peerLabel => widget.peerLabel;

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
      icon: Icons.auto_delete_rounded,
      tone: ToastTone.success,
    );
  }

  Future<void> _shareContact(BuildContext context, WidgetRef ref) async {
    final t = AppLocalizations.of(context);
    // The same chooser forwarding uses: a list of conversations you tick, not
    // a dialog that can be answered once. Sending somebody's card to two
    // people is the ordinary case, and it used to mean opening this twice.
    final chosen = await showChatPicker(
      context,
      title: t.contactProfileShareTitle,
      exceptChatId: peerPubkeyHex,
    );
    if (chosen.isEmpty || !context.mounted) return;

    final peer = ref.read(knownPeersControllerProvider)[peerPubkeyHex];
    final payload = SharedContact(
      pubkeyHex: peerPubkeyHex,
      displayName: peer?.displayName ?? peerLabel,
    ).encode();
    final messaging = ref.read(messagingServiceProvider);
    for (final chat in chosen) {
      if (chat.isChannel) {
        await messaging.sendChannelText(chat.id, payload);
      } else {
        await messaging.sendText(chat.id, payload);
      }
    }
    if (!context.mounted) return;
    showGlassToast(
      context,
      chosen.length == 1
          ? t.contactProfileShareSent(chosen.first.peerName)
          : t.chatForwardSentCount(chosen.length),
      icon: Icons.send_rounded,
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
    // Everything this person leaves behind, in the one place that lists it —
    // see [forgetContactEverywhere]. The Contacts list and the chat list offer
    // the same delete, and three copies of an eleven-step cleanup is three
    // chances for one of them to forget a step.
    await forgetContactEverywhere(ref, peerPubkeyHex);
    if (context.mounted) Navigator.of(context).maybePop();
  }

  /// The panel itself — the dimmed backdrop behind it belongs to
  /// [_ActionsOverlay], which fades it while the card grows.
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
    final tag = ref.watch(contactTagsControllerProvider)[peerPubkeyHex];
    return Stack(
      children: [
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
                  // Scrolls, because the list of things you can do to a
                  // contact has outgrown a short phone: the privacy exceptions
                  // took it 307 points past the bottom of a 360x800 screen,
                  // which a widget test caught before a phone did. A panel
                  // that is shorter than the screen still sizes to its
                  // contents — a scroll view takes the smaller of the two.
                  child: SingleChildScrollView(
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
                                style: AppTypography.heading(size: AppMenu.title),
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
                        icon: Icons.drive_file_rename_outline_rounded,
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
                        icon: Icons.auto_delete_rounded,
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
                        icon: Icons.wallpaper_rounded,
                        label: t.chatWallpaperTitle,
                        onTap: () {
                          close();
                          context.push(
                            '/wallpaper/${Uri.encodeComponent(peerPubkeyHex)}',
                          );
                        },
                      ),
                      _ActionTile(
                        icon: Icons.person_add_alt_1_rounded,
                        label: t.contactProfileShare,
                        onTap: () {
                          close();
                          _shareContact(context, ref);
                        },
                      ),
                      // A label of your own for this person. Local, like the
                      // alias beside it: what you have decided to call
                      // somebody is your business, and telling them would turn
                      // a private note into a message.
                      _ActionTile(
                        icon: Icons.sell_rounded,
                        label: tag == null
                            ? t.contactTagAction
                            : t.contactTagRemove,
                        subtitle: tag,
                        onTap: () async {
                          close();
                          final tags =
                              ref.read(contactTagsControllerProvider.notifier);
                          if (tag != null) {
                            await tags.setTag(peerPubkeyHex, null);
                            return;
                          }
                          final picked = await showEmojiPicker(
                            context,
                            title: t.contactTagTitle,
                          );
                          if (picked == null) return;
                          await tags.setTag(peerPubkeyHex, picked);
                        },
                      ),
                      // Three exceptions to the global privacy switches, for
                      // this one person. Nothing here goes on the wire — each
                      // is a decision not to send something they have no other
                      // way of learning, so the row that turns it on is the
                      // whole of the mechanism.
                      _ActionTile(
                        icon: conversationSettings.hideAvatar
                            ? Icons.visibility_off_rounded
                            : Icons.account_circle_rounded,
                        label: conversationSettings.hideAvatar
                            ? t.contactShowAvatar
                            : t.contactHideAvatar,
                        subtitle: conversationSettings.hideAvatar
                            ? t.contactHiddenFromThem
                            : null,
                        onTap: () async {
                          close();
                          await ref
                              .read(conversationSettingsControllerProvider
                                  .notifier)
                              .setHideAvatar(
                                peerPubkeyHex,
                                !conversationSettings.hideAvatar,
                              );
                        },
                      ),
                      _ActionTile(
                        icon: conversationSettings.hideLastSeen
                            ? Icons.visibility_off_rounded
                            : Icons.schedule_rounded,
                        label: conversationSettings.hideLastSeen
                            ? t.contactShowLastSeen
                            : t.contactHideLastSeen,
                        subtitle: conversationSettings.hideLastSeen
                            ? t.contactHiddenFromThem
                            : null,
                        onTap: () async {
                          close();
                          await ref
                              .read(conversationSettingsControllerProvider
                                  .notifier)
                              .setHideLastSeen(
                                peerPubkeyHex,
                                !conversationSettings.hideLastSeen,
                              );
                        },
                      ),
                      _ActionTile(
                        icon: conversationSettings.hideReadReceipts
                            ? Icons.visibility_off_rounded
                            : Icons.done_all_rounded,
                        label: conversationSettings.hideReadReceipts
                            ? t.contactShowReadReceipts
                            : t.contactHideReadReceipts,
                        subtitle: conversationSettings.hideReadReceipts
                            ? t.contactHiddenFromThem
                            : null,
                        onTap: () async {
                          close();
                          await ref
                              .read(conversationSettingsControllerProvider
                                  .notifier)
                              .setHideReadReceipts(
                                peerPubkeyHex,
                                !conversationSettings.hideReadReceipts,
                              );
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
                        icon: Icons.person_remove_rounded,
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
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
    // Theirs as well as ours: a peer whose own switch is off says so on every
    // beacon, and this is the screen that would otherwise print the very clock
    // they asked us not to.
    final theirBeacon = ref.watch(presenceControllerProvider)[peerPubkeyHex];
    final hideTimes = !presenceShared || (theirBeacon?.hidesLastSeen ?? false);
    final active =
        contact?.isOnline == true || contact?.isReachableViaMesh == true;
    final String status;
    if (contact?.isOnline == true) {
      status = t.presenceOnline;
    } else if (contact?.isReachableViaMesh == true) {
      status = t.chatsStatusViaMesh;
    } else if (hideTimes) {
      status = t.presenceRecently;
    } else if (peer == null) {
      status = t.presenceOffline;
    } else {
      status = [
        t.presenceOffline,
        formatChatListTime(context, peer.lastSeen),
      ].join(' \u00B7 ');
    }
    final heroExpanded =
        (MediaQuery.sizeOf(context).height * 0.61).clamp(430.0, 560.0);
    final heroCompact = _ProfileHero.compactHeightFor(
      MediaQuery.paddingOf(context).top,
    );

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
              NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: CustomScrollView(
                // Bouncing on both platforms: Android's clamping physics never
                // lets `pixels` go below zero, so "pulled past the top" would
                // have nothing to measure and the gesture would only exist on
                // an iPhone.
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: AnimatedBuilder(
                      animation: _open,
                      builder: (context, _) => _ProfileHero(
                      t: _open.value,
                      compact: heroCompact,
                      expanded: heroExpanded,
                      onFaceTap: _toggleFace,
                      onFaceDragStart: _faceDragStart,
                      onFaceDrag: _faceDrag,
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
                                      : Icons.shield_rounded,
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
              ),
              Positioned.fill(
                child: _ActionsOverlay(
                  open: actionsOpen,
                  onDismiss: closeActions,
                  builder: (context) =>
                      _actionsPanel(context, ref, peer, closeActions),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The actions panel's way in and out.
///
/// It used to appear and vanish on a boolean, which is the same "deleted
/// rather than dismissed" every menu in the app was fixed of earlier — see
/// `glassMenuMotion` in `core/widgets/context_popup.dart`. This is that motion,
/// spelled out locally because this
/// panel is an overlay inside the screen rather than a route: the same 210 ms
/// in and 170 ms out, eased both ways, with the card growing from the top
/// right corner where the button that opened it sits.
///
/// Closed and settled, it is a `SizedBox` — the panel is not built, so its
/// blur is not in the tree and nothing behind it is snapshotted.
class _ActionsOverlay extends StatefulWidget {
  const _ActionsOverlay({
    required this.open,
    required this.onDismiss,
    required this.builder,
  });

  final bool open;
  final VoidCallback onDismiss;
  final WidgetBuilder builder;

  @override
  State<_ActionsOverlay> createState() => _ActionsOverlayState();
}

class _ActionsOverlayState extends State<_ActionsOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 210),
    reverseDuration: const Duration(milliseconds: 170),
    value: widget.open ? 1 : 0,
  );

  late final Animation<double> _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(covariant _ActionsOverlay old) {
    super.didUpdateWidget(old);
    if (widget.open == old.open) return;
    if (widget.open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// True while there is nothing to show: closed, and finished closing.
  ///
  /// `widget.open` is half of it and not a formality — on the frame the panel
  /// is first asked for, the controller has not ticked yet and still reads
  /// dismissed. Testing the controller alone there returns nothing, nothing
  /// schedules a frame, and the panel never opens at all.
  bool get _gone => !widget.open && _controller.isDismissed;

  @override
  Widget build(BuildContext context) {
    // Built here rather than inside the animated builder so the panel is made
    // once per rebuild instead of once per frame — and not at all while the
    // menu is closed, which is what keeps its blur out of the tree.
    final panel = _gone ? null : Builder(builder: widget.builder);
    return AnimatedBuilder(
      animation: _controller,
      child: panel,
      // Rebuilding the shape here, rather than off a status listener, is what
      // takes the panel out of the tree on the *same* frame the animation
      // ends. A listener calling setState leaves it standing one frame longer
      // — invisible, but still findable, which is a difference a test can see
      // and a stray tap can land on.
      builder: (context, child) {
        if (child == null || _gone) return const SizedBox.shrink();
        return IgnorePointer(
          // On the way out the panel is still painted, and a card that goes on
          // eating taps while it fades swallows whatever was reached for next.
          ignoring: !widget.open,
          child: Stack(
            children: [
              Positioned.fill(
                child: FadeTransition(
                  opacity: _curved,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDismiss,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.46),
                    ),
                  ),
                ),
              ),
              FadeTransition(
                opacity: _curved,
                child: ScaleTransition(
                  alignment: Alignment.topRight,
                  scale: Tween<double>(begin: 0.88, end: 1).animate(_curved),
                  child: child,
                ),
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
    required this.t,
    required this.compact,
    required this.expanded,
    required this.onFaceTap,
    required this.onFaceDragStart,
    required this.onFaceDrag,
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

  /// 0 = a circle in the middle, 1 = the picture filling the header.
  final double t;

  /// The two heights it lerps between.
  final double compact;
  final double expanded;

  final VoidCallback onFaceTap;
  final VoidCallback onFaceDragStart;
  final ValueChanged<DragUpdateDetails> onFaceDrag;

  /// The circle at rest, matched to the profile's own so the two headers are
  /// the same size when they are showing the same thing.
  static const double faceSize = 92;

  /// Room under the circle for the name and the line beneath it.
  static const double nameBlockRoom = 62;

  /// The quick-action card and the gap under it.
  static const double actionsHeight = 84;

  /// Inset, face, the two lines, the actions card. The list's own padding
  /// follows this rather than a fixed number.
  static double compactHeightFor(double topInset) =>
      topInset + 12 + faceSize + 10 + nameBlockRoom + 12 + actionsHeight + 12;
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
    // Their picture, full-bleed across the header — the same thing your own
    // profile does with yours. A round portrait floating on a gradient was the
    // one place in the app where somebody's face was shown as a token rather
    // than as a photograph, and the round one below it is still there for the
    // identity it carries (the online dot, the letters when there is no photo).
    final photo = ref.watch(peerAvatarsControllerProvider)[peerId];
    return LayoutBuilder(
      builder: (context, constraints) =>
          _body(context, ref, photo, palette, constraints.maxWidth),
    );
  }

  /// The header, given the width it is actually being drawn at.
  ///
  /// From the layout rather than from `MediaQuery`: they are the same number
  /// on a phone and are not the same number under a capture harness, where a
  /// face centred on the media query lands half off the edge of the boundary
  /// it is drawn into.
  Widget _body(
    BuildContext context,
    WidgetRef ref,
    Uint8List? photo,
    List<Color> palette,
    double width,
  ) {
    final topInset = MediaQuery.paddingOf(context).top;
    final height = ui.lerpDouble(compact, expanded, t)!;

    // The face and the header are the same rectangle at two sizes: a circle in
    // the middle at rest, the whole width once it is opened. Lerping the rect
    // and its corner radius together is what makes one grow into the other,
    // the same way your own profile does.
    final rect = Rect.lerp(
      Rect.fromLTWH((width - faceSize) / 2, topInset + 12, faceSize, faceSize),
      Rect.fromLTWH(0, 0, width, height),
      t,
    )!;
    final radius = ui.lerpDouble(faceSize / 2, 0, t)!;

    // Under the circle at rest; above the actions once the picture is open.
    final nameTop = ui.lerpDouble(
      topInset + 12 + faceSize + 10,
      height - actionsHeight - 12 - nameBlockRoom - 8,
      t,
    )!;

    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            // Keyed for the test that measures where it sits: "centred" is a
            // number, and a golden can show it but cannot check it.
            key: const ValueKey('contact-hero-face'),
            child: RawGestureDetector(
              // The picture answers the gesture that is about the picture: up
              // opens it, down closes it, a tap does either. Raw and eager,
              // because the list is listening for a vertical drag too and an
              // ordinary detector loses that arena outright.
              gestures: <Type, GestureRecognizerFactory>{
                EagerVerticalDragRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        EagerVerticalDragRecognizer>(
                  EagerVerticalDragRecognizer.new,
                  (r) => r
                    ..onStart = ((_) => onFaceDragStart())
                    ..onUpdate = onFaceDrag,
                ),
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  TapGestureRecognizer.new,
                  (r) => r.onTap = onFaceTap,
                ),
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: photo != null
                    ? Image.memory(
                        photo,
                        fit: BoxFit.cover,
                        // Full HD bytes so the open header stays sharp;
                        // decoded at the size actually drawn.
                        cacheWidth:
                            (width * MediaQuery.devicePixelRatioOf(context))
                                .round(),
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      )
                    : DecoratedBox(
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
                        // With no photograph the circle carries the identity —
                        // the letters, the online dot. Open, the gradient is
                        // the whole header and a disc on top of it would be
                        // the same colours twice.
                        child: t < 0.5
                            ? Center(
                                child: PeerAvatar(
                                  peerId: peerId,
                                  label: label,
                                  size: faceSize,
                                  online: online,
                                ),
                              )
                            : null,
                      ),
              ),
            ),
          ),
          // Only over the photograph: at rest the header is the app's own
          // background and a scrim on that is a smudge.
          if (t > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: height * 0.55,
              child: IgnorePointer(
                child: Opacity(
                  opacity: t,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0x00000000),
                          AppColors.bgDeep.withValues(alpha: 0.90),
                        ],
                      ),
                    ),
                  ),
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
            // Clear of the two round buttons at rest so a long name cannot run
            // under them; back to 20 once the picture is open and the buttons
            // are far above the text.
            left: ui.lerpDouble(56, 20, t)!,
            top: nameTop,
            right: ui.lerpDouble(56, 20, t)!,
            child: Align(
              alignment: Alignment(ui.lerpDouble(0, -1, t)!, 0),
              child: Column(
                crossAxisAlignment: t < 0.5
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: t < 0.5 ? TextAlign.center : TextAlign.start,
                    style: AppTypography.display(
                      size: ui.lerpDouble(24, 31, t)!,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: t < 0.5 ? TextAlign.center : TextAlign.start,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
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
                      icon: Icons.verified_user_rounded,
                      label: verifyLabel,
                      onTap: onVerify,
                    ),
                    _QuickAction(
                      icon: blocked ? Icons.lock_open_rounded : Icons.block_rounded,
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
          icon: Icon(icon, color: AppColors.textOnGlass, size: AppMenu.buttonIcon),
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
        leading: Icon(icon, color: tone, size: AppMenu.rowIcon),
        title: Text(
          label,
          style: TextStyle(
            color: tone,
            fontSize: AppMenu.rowLabel,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: AppMenu.rowSubtitle,
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
              icon: Icons.photo_library_rounded,
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
              icon: Icons.folder_rounded,
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
