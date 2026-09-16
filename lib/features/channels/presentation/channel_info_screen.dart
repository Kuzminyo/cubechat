import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/identity/avatar_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/transport/channel_admin.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/util/image_encode.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/widgets/image_editor.dart';
import '../../chat/presentation/widgets/media_picker_sheet.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/models/known_peer.dart';
import '../data/channel_avatars_controller.dart';
import '../data/channel_controller.dart';
import '../../chat/data/conversation_settings_controller.dart';
import '../data/channel_descriptions_controller.dart';
import '../data/channel_roster_controller.dart';
import 'channel_invite_sheet.dart';

class ChannelInfoScreen extends ConsumerStatefulWidget {
  const ChannelInfoScreen({super.key, required this.channelName});

  final String channelName;

  @override
  ConsumerState<ChannelInfoScreen> createState() => _ChannelInfoScreenState();
}

class _ChannelInfoScreenState extends ConsumerState<ChannelInfoScreen> {
  String? _myId;

  @override
  void initState() {
    super.initState();
    Future<void>(() async {
      final member = await ref
          .read(channelRosterControllerProvider.notifier)
          .ensureSelf(widget.channelName, adminWhenFirst: true);
      if (mounted) setState(() => _myId = member.id);
    });
  }

  /// A roster member carries the first 16 hex characters of the author's
  /// Ed25519 key, not a routing address — that is all a signed channel frame
  /// reveals. Matching it back against the contacts we already hold is what
  /// makes a row something you can tap through; somebody we have never met 1:1
  /// resolves to nothing, and stays a plain row rather than a dead link.
  ///
  /// Built once per rebuild rather than searched per row, and off a watched
  /// roster, so a member who becomes a contact while this screen is open turns
  /// into a link without having to leave and come back.
  static Map<String, KnownPeer> _byFingerprint(Map<String, KnownPeer> peers) {
    final out = <String, KnownPeer>{};
    for (final peer in peers.values) {
      final signPub = peer.signPublicKey;
      if (signPub == null) continue;
      out[[
        for (final b in signPub.take(8)) b.toRadixString(16).padLeft(2, '0'),
      ].join()] = peer;
    }
    return out;
  }

  /// Hand a member our contact card so they can write to us outside the room.
  Future<void> _inviteToContacts(ChannelMember member) async {
    final t = AppLocalizations.of(context);
    try {
      await ref
          .read(messagingServiceProvider)
          .sendChannelContactInvite(widget.channelName, member.id);
      if (!mounted) return;
      showGlassToast(
        context,
        t.channelContactInviteSent(member.name),
        icon: Icons.person_add_alt_1_rounded,
        tone: ToastTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }

  /// Remove somebody from the room, or silence them for a while.
  ///
  /// Behind a long press on their row, and offered only to an administrator
  /// looking at somebody who is not one. An administrator cannot be moderated
  /// at all — the transport refuses it too — because seniority is not
  /// something this protocol can establish, and two admins able to remove each
  /// other leaves every phone in the room with a different answer.
  Future<void> _moderate(ChannelMember member) async {
    final t = AppLocalizations.of(context);
    final messaging = ref.read(messagingServiceProvider);
    final cleared = member.isMutedNow || member.isRemoved;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgTop,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  member.name.isEmpty ? t.channelMemberActions : member.name,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (cleared)
              ListTile(
                leading: Icon(Icons.undo_rounded,
                    color: AppColors.brandPrimary),
                title: Text(
                  t.channelUnmuteMember,
                  style: TextStyle(color: AppColors.textOnGlass),
                ),
                onTap: () => Navigator.of(sheetContext).pop('clear'),
              ),
            ListTile(
              leading: Icon(Icons.volume_off_rounded,
                  color: AppColors.textOnGlass),
              title: Text(
                t.channelMuteMember,
                style: TextStyle(color: AppColors.textOnGlass),
              ),
              onTap: () => Navigator.of(sheetContext).pop('mute'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.person_remove_rounded,
                      color: AppColors.danger),
              title: Text(
                t.channelRemoveMember,
                style: const TextStyle(color: AppColors.danger),
              ),
              subtitle: Text(
                t.channelRemoveMemberHint,
                style: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 11.5,
                ),
              ),
              onTap: () => Navigator.of(sheetContext).pop('remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    DateTime? until;
    if (choice == 'mute') {
      var minutes = await _pickMuteMinutes();
      if (minutes == null || !mounted) return;
      if (minutes < 0) {
        // However long the administrator says. The presets are shortcuts, not
        // the set of answers — asked for directly, and the wire has carried an
        // arbitrary deadline since it was written.
        minutes = await _askMuteMinutes();
        if (minutes == null || !mounted) return;
      }
      // Zero is the "until I say otherwise" row: a mute with no deadline is a
      // null [ChannelModeration.until], which the wire already means.
      until =
          minutes == 0 ? null : DateTime.now().add(Duration(minutes: minutes));
    }

    try {
      await messaging.sendChannelModeration(
        widget.channelName,
        memberId: member.id,
        action: switch (choice) {
          'remove' => ChannelModerationAction.remove,
          'mute' => ChannelModerationAction.mute,
          _ => ChannelModerationAction.clear,
        },
        until: until,
      );
      if (!mounted) return;
      showGlassToast(
        context,
        switch (choice) {
          'remove' => t.channelMemberRemoved(member.name),
          'mute' => t.channelMemberMuted(member.name),
          _ => t.channelMemberCleared(member.name),
        },
        icon: choice == 'remove'
            ? Icons.person_remove_rounded
            : Icons.volume_off_rounded,
        tone: choice == 'remove' ? ToastTone.danger : ToastTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }

  /// A number of hours typed by hand.
  ///
  /// Bounded by what the wire can hold — five bytes of unix seconds, which runs
  /// out well past any lifetime — and by what a moderator plausibly means: a
  /// year is already "indefinitely with extra steps", and the row above this
  /// one says that more honestly.
  Future<int?> _askMuteMinutes() async {
    final t = AppLocalizations.of(context);
    final controller = TextEditingController();
    final entered = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.glass(0.15)),
        ),
        title: Text(
          t.channelMuteCustom,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: TextStyle(color: AppColors.textOnGlass),
          decoration: InputDecoration(
            hintText: t.channelMuteCustomHint,
            hintStyle: TextStyle(color: AppColors.textOnGlassFaint),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(
            int.tryParse(value.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              t.cancel,
              style: TextStyle(color: AppColors.textOnGlassDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              int.tryParse(controller.text.trim()),
            ),
            child: Text(
              t.channelMuteMember,
              style: TextStyle(color: AppColors.brandPrimary),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null) return null;
    // A typo must not become a silence nobody can explain: out of range is
    // treated as no answer rather than clamped into one.
    if (entered < 1 || entered > 60 * 24 * 365) return null;
    return entered;
  }

  /// How long a mute lasts, in minutes. Zero means no end, and -1 means ask.
  ///
  /// Minutes rather than whole hours, because an hour is already a long time
  /// to stop somebody talking and the shortest thing the picker could express
  /// was one. The wire has always carried a deadline to the second.
  Future<int?> _pickMuteMinutes() async {
    final t = AppLocalizations.of(context);
    const choices = <int>[5, 60, 480, 2880];
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.bgTop,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final minutes in choices)
              ListTile(
                title: Text(
                  minutes < 60
                      ? t.channelMuteMinutes(minutes)
                      : minutes < 60 * 24
                          ? t.channelMuteHours(minutes ~/ 60)
                          : t.channelMuteDays(minutes ~/ (60 * 24)),
                  style: TextStyle(color: AppColors.textOnGlass),
                ),
                onTap: () => Navigator.of(sheetContext).pop(minutes),
              ),
            ListTile(
              title: Text(
                t.channelMuteCustom,
                style: TextStyle(color: AppColors.textOnGlass),
              ),
              trailing: Icon(
                Icons.edit_rounded,
                size: 18,
                color: AppColors.textOnGlassFaint,
              ),
              // -1 is "ask me": the sheet cannot host a field of its own
              // without fighting the keyboard for the space it is standing in.
              onTap: () => Navigator.of(sheetContext).pop(-1),
            ),
            ListTile(
              title: Text(
                t.channelMuteForever,
                style: TextStyle(color: AppColors.textOnGlass),
              ),
              onTap: () => Navigator.of(sheetContext).pop(0),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Put the room's recent posts back on the air for whoever joined after they
  /// were said.
  ///
  /// Deliberate rather than automatic — see
  /// [MessagingService.sendChannelHistory]. Members who were already here
  /// receive it and store nothing, because every post carries the id it
  /// originally travelled under.
  Future<void> _shareHistory() async {
    final t = AppLocalizations.of(context);
    try {
      final count = await ref
          .read(messagingServiceProvider)
          .sendChannelHistory(widget.channelName);
      if (!mounted) return;
      showGlassToast(
        context,
        count == 0 ? t.channelHistoryNothing : t.channelHistoryShared(count),
        icon: Icons.history_rounded,
        tone: count == 0 ? ToastTone.danger : ToastTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }

  Future<void> _pickChannelAvatar() async {
    final t = AppLocalizations.of(context);
    final result = await showGlassSheet<MediaPickerResult>(
      context: context,
      useRootNavigator: true,
      builder: (_) =>
          const MediaPickerSheet(allowFiles: false, allowCaption: false),
    );
    if (result is! MediaPickerAssets || result.assets.isEmpty) return;

    // The same size the personal avatar asks for, and the reason the room's
    // picture stayed soft after the encoder learned to carry a bigger one:
    // this is where the resolution was being thrown away. A thousand and
    // twenty-four pixels, then a crop out of the middle of that, is what every
    // later step had to work from — no ladder further down can put back what
    // was never handed to it.
    final preview = await result.assets.first.thumbnailDataWithSize(
      const ThumbnailSize(
        AvatarController.storedSize,
        AvatarController.storedSize,
      ),
      quality: 95,
    );
    if (preview == null) {
      if (mounted) showGlassToast(context, t.avatarFailed);
      return;
    }
    if (!mounted) return;

    // Same crop-it-yourself step the personal avatar gets: a centre crop of a
    // portrait photo is a decision nobody asked the app to make.
    final cropped = await openImageEditor(context, preview);
    if (cropped == null || !mounted) return;

    final jpeg = await encodeChannelAvatar(
      cropped,
      // The room's picture is chunked when it will not fit one frame, so the
      // ceiling is what is reasonable to put on the air once rather than what
      // the fragmenter can split. Same number the personal avatar uses.
      maxBytes: AvatarController.shareByteBudget,
    );
    if (!mounted) return;
    if (jpeg == null) {
      showGlassToast(context, t.channelAvatarTooLarge, tone: ToastTone.danger);
      return;
    }
    await _publishAvatar(jpeg);
  }

  Future<void> _removeChannelAvatar() async {
    final t = AppLocalizations.of(context);
    if (!await confirmAction(
      context,
      title: t.avatarRemove,
      message: t.avatarRemoveConfirm,
      confirmLabel: t.avatarRemove,
    )) {
      return;
    }
    await _publishAvatar(null);
  }

  Future<void> _editDescription(String current) async {
    final t = AppLocalizations.of(context);
    final controller = TextEditingController(text: current);
    final text = await showGlassSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            // Not the keyboard inset: showGlassSheet already lifts the sheet
            // by it, and adding it again pushed the button below the fold.
            16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.channelDescriptionTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 4,
                minLines: 2,
                maxLength: kChannelDescriptionMaxLength,
                style: TextStyle(color: AppColors.textOnGlass),
                decoration: InputDecoration(
                  hintText: t.channelDescriptionHint,
                  hintStyle: TextStyle(color: AppColors.textOnGlassDim),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.black,
                ),
                onPressed: () =>
                    Navigator.of(sheetContext).pop(controller.text),
                child: Text(t.channelDescriptionSave),
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();
    // Backing out leaves the topic alone; an empty box is a deliberate clear.
    if (text == null || !mounted) return;
    try {
      await ref
          .read(messagingServiceProvider)
          .sendChannelDescription(widget.channelName, text);
    } catch (e) {
      if (mounted) showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }

  Future<void> _publishAvatar(Uint8List? jpeg) async {
    final t = AppLocalizations.of(context);
    try {
      await ref
          .read(messagingServiceProvider)
          .sendChannelAvatar(widget.channelName, jpeg);
    } catch (e) {
      if (mounted) {
        showGlassToast(context, '$e', tone: ToastTone.danger);
      }
      return;
    }
    if (mounted) showGlassToast(context, t.channelSubtitle);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    ref.watch(channelRosterControllerProvider);
    final roster = ref.read(channelRosterControllerProvider.notifier);
    final members = roster.membersFor(widget.channelName);
    // A real check: [ensureSelf] in initState has already claimed the admin
    // seat if it was unclaimed and we did not arrive by invitation, so a room
    // reaching this line has an owner and "am I it" is a question with a
    // meaning again.
    final canManage =
        _myId != null && roster.isAdmin(widget.channelName, _myId!);
    final adminOnly = ref
            .watch(channelControllerProvider)[widget.channelName]
            ?.adminOnly ??
        false;
    final picture =
        ref.watch(channelAvatarsControllerProvider).isEmpty
            ? null
            : ref
                .read(channelAvatarsControllerProvider.notifier)
                .forChannel(widget.channelName);
    final contacts = _byFingerprint(ref.watch(knownPeersControllerProvider));
    final description =
        ref.watch(channelDescriptionsControllerProvider)[widget.channelName];

    final admins = [for (final m in members) if (m.isAdmin) m];
    final muted = ref
            .watch(conversationSettingsControllerProvider)[widget.channelName]
            ?.isMutedNow ??
        false;

    // The shape a channel has everywhere else: the picture across the top with
    // the name over it, a row of round actions, and the rest as rows you open
    // rather than a page of switches. Asked for with screenshots, and the
    // member's version is the same screen with the administrator's half taken
    // out — no greyed-out controls, no toasts explaining what somebody cannot
    // do here.
    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _ChannelCover(
              channelName: widget.channelName,
              picture: picture,
              memberCount: members.length,
              canManage: canManage,
              onBack: () => Navigator.of(context).maybePop(),
              onEdit: canManage ? _editChannel : null,
              onOpenPicture: picture == null
                  ? null
                  : () => _openPicture(picture),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  if (canManage)
                    _RoundAction(
                      icon: Icons.person_add_alt_1_rounded,
                      label: t.channelInviteTitle,
                      onTap: () =>
                          showChannelInviteSheet(context, widget.channelName),
                    )
                  else
                    _RoundAction(
                      icon: Icons.ios_share_rounded,
                      label: t.channelShareAction,
                      onTap: () =>
                          showChannelInviteSheet(context, widget.channelName),
                    ),
                  const SizedBox(width: 10),
                  _RoundAction(
                    icon: muted
                        ? Icons.notifications_off_rounded
                        : Icons.notifications_active_rounded,
                    label: muted ? t.channelUnmute : t.channelMute,
                    onTap: () => _toggleMute(muted),
                  ),
                  const SizedBox(width: 10),
                  _RoundAction(
                    icon: Icons.perm_media_rounded,
                    label: t.channelSharedContent,
                    // The channel's own bucket keys the shared-content screen
                    // exactly the way a peer's pubkey does, so the media,
                    // files and polls tabs come for free.
                    onTap: () => context.push(
                      '/person/${Uri.encodeComponent(widget.channelName)}'
                      '/content?name=${Uri.encodeComponent(widget.channelName)}',
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (canManage)
                    _RoundAction(
                      icon: Icons.wallpaper_rounded,
                      label: t.chatWallpaperTitle,
                      onTap: () => context.push(
                        '/wallpaper/${Uri.encodeComponent(widget.channelName)}',
                      ),
                    )
                  else
                    _RoundAction(
                      icon: Icons.logout_rounded,
                      label: t.channelLeaveAction,
                      tone: AppColors.danger,
                      onTap: _leaveChannel,
                    ),
                ],
              ),
            ),
            if (description != null && description.isNotEmpty) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _ChannelDescription(
                  text: description,
                  canManage: canManage,
                  onTap: canManage
                      ? () => _editDescription(description)
                      : () => showGlassToast(
                            context,
                            t.channelDescriptionAdminOnly,
                          ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _InfoRow(
                      icon: Icons.group_rounded,
                      label: t.channelParticipantsTitle,
                      trailing: '${members.length}',
                      onTap: () => _showPeople(members, contacts, canManage),
                    ),
                    _InfoRow(
                      icon: Icons.shield_rounded,
                      label: t.channelAdministratorsTitle,
                      trailing: '${admins.length}',
                      onTap: () => _showPeople(admins, contacts, canManage),
                    ),
                    if (canManage)
                      _InfoRow(
                        icon: Icons.tune_rounded,
                        label: t.channelSettingsTitle,
                        subtitle: t.channelSettingsHint,
                        onTap: () => _showSettings(adminOnly),
                        last: true,
                      )
                    else
                      _InfoRow(
                        icon: Icons.wallpaper_rounded,
                        label: t.chatWallpaperTitle,
                        onTap: () => context.push(
                          '/wallpaper/'
                          '${Uri.encodeComponent(widget.channelName)}',
                        ),
                        last: true,
                      ),
                  ],
                ),
              ),
            ),
            // The end of the room, and only for the one person who can end it.
            // Below everything else rather than among the settings, because it
            // is not a setting.
            if (_myId != null &&
                roster.isOwner(widget.channelName, _myId!)) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GlassCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.delete_forever_rounded,
                      color: AppColors.danger,
                    ),
                    title: Text(
                      t.channelCloseTitle,
                      style: const TextStyle(
                        color: AppColors.danger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      t.channelCloseSubtitle,
                      style: TextStyle(
                        color: AppColors.textOnGlassDim,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    onTap: _closeForEveryone,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Silence the room, or let it speak again. The same switch the row used to
  /// carry, now behind the bell in the action strip.
  Future<void> _toggleMute(bool muted) async {
    await ref
        .read(conversationSettingsControllerProvider.notifier)
        .setMuted(widget.channelName, !muted);
  }

  /// The picture at full size, the way a contact's opens.
  void _openPicture(Uint8List picture) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.memory(picture, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  /// The pencil: the room's picture and its description, which are the two
  /// things an administrator can change about it.
  Future<void> _editChannel() async {
    final t = AppLocalizations.of(context);
    final picture = ref
        .read(channelAvatarsControllerProvider.notifier)
        .forChannel(widget.channelName);
    final description =
        ref.read(channelDescriptionsControllerProvider)[widget.channelName];
    if (!mounted) return;
    final action = await showGlassSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _InfoRow(
              icon: Icons.photo_camera_rounded,
              label: t.channelAvatarSet,
              onTap: () => Navigator.of(sheet).pop('photo'),
            ),
            if (picture != null)
              _InfoRow(
                icon: Icons.hide_image_rounded,
                label: t.avatarRemove,
                tone: AppColors.danger,
                onTap: () => Navigator.of(sheet).pop('remove'),
              ),
            _InfoRow(
              icon: Icons.notes_rounded,
              label: t.channelDescriptionTitle,
              onTap: () => Navigator.of(sheet).pop('description'),
              last: true,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'photo':
        await _pickChannelAvatar();
      case 'remove':
        await _removeChannelAvatar();
      case 'description':
        await _editDescription(description ?? '');
    }
  }

  /// The room's people, in a sheet rather than down the page: thirty of them
  /// under the settings is a screen nobody scrolls to the bottom of.
  void _showPeople(
    List<ChannelMember> people,
    Map<String, KnownPeer> contacts,
    bool canManage,
  ) {
    final t = AppLocalizations.of(context);
    showGlassSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: people.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  t.channelNoParticipants,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textOnGlassDim),
                ),
              )
            : ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  for (final member in people)
                    _MemberRow(
                      member: member,
                      contact: contacts[member.id],
                      isMe: member.id == _myId,
                      canManage: canManage,
                      onInvite: () => _inviteToContacts(member),
                      onModerate: () => _moderate(member),
                      onToggleAdmin: () => ref
                          .read(messagingServiceProvider)
                          .sendChannelAdminChange(
                            widget.channelName,
                            member.id,
                            !member.isAdmin,
                          ),
                    ),
                ],
              ),
      ),
    );
  }

  /// Everything the room's administrator decides, in one place.
  void _showSettings(bool adminOnly) {
    final t = AppLocalizations.of(context);
    showGlassSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          children: [
            _ChannelCopyRestriction(
              channelName: widget.channelName,
              canManage: true,
            ),
            const SizedBox(height: 12),
            _ChannelAdminOnly(
              channelName: widget.channelName,
              canManage: true,
            ),
            // Only where a backlog is safe to hand over: a channel frame is
            // signed by whoever sent it, so replaying somebody else's words
            // under our own signature is only honest in a room where the
            // administrator wrote all of them. The receiving side refuses it
            // anywhere else — see [MessagingService.sendChannelHistory].
            if (adminOnly) ...[
              const SizedBox(height: 12),
              _ChannelAutoHistory(channelName: widget.channelName),
              const SizedBox(height: 12),
              GlassCard(
                onTap: _shareHistory,
                child: Row(
                  children: [
                    Icon(Icons.history_rounded, color: AppColors.brandPrimary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.channelShareHistory,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            t.channelShareHistoryHint,
                            style: TextStyle(
                              color: AppColors.textOnGlassFaint,
                              fontSize: 11.5,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            GlassCard(
              onTap: () => context.push(
                '/wallpaper/${Uri.encodeComponent(widget.channelName)}',
              ),
              child: Row(
                children: [
                  Icon(Icons.wallpaper_rounded, color: AppColors.brandPrimary),
                  const SizedBox(width: 12),
                  Text(
                    t.chatWallpaperTitle,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Leave the room: it goes from this phone and nothing is said to anybody.
  /// The key comes from the name, so this is not a door that locks.
  Future<void> _leaveChannel() async {
    final t = AppLocalizations.of(context);
    if (!await confirmAction(
      context,
      title: t.channelLeaveAction,
      message: t.channelLeaveConfirm,
      confirmLabel: t.channelLeaveAction,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    await ref
        .read(messagingServiceProvider)
        .wipeChannelLocally(widget.channelName);
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// End the room, on every phone that has it.
  ///
  /// Two sentences in the confirmation and both of them true: everything goes
  /// from everyone, and nobody is locked out — the key comes from the name, so
  /// anyone who remembers it can type it again into an empty room. Promising
  /// otherwise would be the one lie this screen could tell that somebody would
  /// find out the hard way.
  Future<void> _closeForEveryone() async {
    final t = AppLocalizations.of(context);
    final sure = await confirmAction(
      context,
      title: t.channelCloseTitle,
      message: t.channelCloseConfirm,
      confirmLabel: t.channelCloseAction,
    );
    if (!sure || !mounted) return;
    try {
      await ref
          .read(messagingServiceProvider)
          .sendChannelDeleteForEveryone(widget.channelName);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }
}

/// Announcement mode: only admins may post.
///
/// The switch is a request; the enforcement lives on every member's device,
/// which drops posts signed by anyone their roster does not hold as an admin.
/// See [Channel.adminOnly] — with a shared key there is no way to stop a frame
/// being sent, only to decline to accept it.
class _ChannelAdminOnly extends ConsumerWidget {
  const _ChannelAdminOnly({
    required this.channelName,
    required this.canManage,
  });

  final String channelName;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final on = ref
            .watch(channelControllerProvider.notifier)
            .byName(channelName)
            ?.adminOnly ??
        false;
    ref.watch(channelControllerProvider);

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            Icon(
              on ? Icons.campaign_rounded : Icons.forum_rounded,
              size: 19,
              color: AppColors.textOnGlassDim,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.channelAdminOnly,
                    style:
                        TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.channelAdminOnlyHint,
                    style: TextStyle(
                        color: AppColors.textOnGlassDim, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            Switch(
              value: on,
              onChanged: (next) async {
                if (!canManage) {
                  showGlassToast(context, t.channelAdminOnly);
                  return;
                }
                try {
                  await ref
                      .read(messagingServiceProvider)
                      .sendChannelAdminOnly(channelName, next);
                } catch (e) {
                  if (!context.mounted) return;
                  showGlassToast(context, t.channelAdminOnly);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelCopyRestriction extends ConsumerWidget {
  const _ChannelCopyRestriction({
    required this.channelName,
    required this.canManage,
  });

  final String channelName;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final settings =
        ref.watch(conversationSettingsControllerProvider)[channelName];
    final on = settings?.copyingRestricted ?? false;

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            Icon(
              on ? Icons.layers_clear_rounded : Icons.copy_all_rounded,
              size: 19,
              color: AppColors.textOnGlassDim,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t.contactProfileRestrictCopying,
                style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
              ),
            ),
            Switch(
              value: on,
              // Same treatment as the picture and the topic: a member sees the
              // state rather than a hidden control, and is told why it will not
              // move rather than watching a tap do nothing.
              onChanged: (next) async {
                if (!canManage) {
                  showGlassToast(context, t.channelAdminOnly);
                  return;
                }
                try {
                  await ref
                      .read(messagingServiceProvider)
                      .sendChannelCopyRestriction(channelName, next);
                } catch (e) {
                  if (!context.mounted) return;
                  showGlassToast(context, t.channelAdminOnly);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Hand the backlog over on its own, whenever somebody new arrives.
///
/// Local to this phone: it decides what *we* offer, and there is nothing to
/// tell the room. The manual button below it stays, because a switch turned on
/// today does nothing for the people who joined last week.
class _ChannelAutoHistory extends ConsumerWidget {
  const _ChannelAutoHistory({required this.channelName});

  final String channelName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final on = ref.watch(
      channelControllerProvider.select(
        (all) => all[channelName]?.shareHistory ?? false,
      ),
    );
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            Icon(
              on ? Icons.history_rounded : Icons.history_toggle_off_rounded,
              size: 19,
              color: AppColors.textOnGlassDim,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.channelHistoryAuto,
                    style:
                        TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    t.channelHistoryAutoHint,
                    style: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: on,
              onChanged: (next) => ref
                  .read(channelControllerProvider.notifier)
                  .setShareHistory(channelName, next),
            ),
          ],
        ),
      ),
    );
  }
}

/// The room's own words, under the actions: a card rather than a row, because
/// a description is read here and not opened. An administrator taps it to
/// write one; anybody else is told who may.
class _ChannelDescription extends StatelessWidget {
  const _ChannelDescription({
    required this.text,
    required this.canManage,
    required this.onTap,
  });

  final String? text;
  final bool canManage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final body = text?.trim() ?? '';
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.channelDescriptionTitle.toUpperCase(),
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body.isEmpty ? t.channelDescriptionEmpty : body,
                  style: TextStyle(
                    color: body.isEmpty
                        ? AppColors.textOnGlassFaint
                        : AppColors.textOnGlass,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (canManage) ...[
            const SizedBox(width: 8),
            Icon(Icons.edit_rounded, size: 18, color: AppColors.brandPrimary),
          ],
        ],
      ),
    );
  }
}

/// The top of the screen: the room's picture across the width, its name over
/// the bottom of it, and the controls that belong to the picture itself.
///
/// A cover rather than a card, which is what a channel looks like everywhere
/// else and what was asked for with screenshots. With no picture the same
/// space is the room's own colour with its initial in it, so the screen does
/// not change shape when one is set.
class _ChannelCover extends StatelessWidget {
  const _ChannelCover({
    required this.channelName,
    required this.picture,
    required this.memberCount,
    required this.canManage,
    required this.onBack,
    this.onEdit,
    this.onOpenPicture,
  });

  final String channelName;
  final Uint8List? picture;
  final int memberCount;
  final bool canManage;
  final VoidCallback onBack;

  /// The pencil, for an administrator: the picture and the description.
  final VoidCallback? onEdit;

  /// Tapping the picture opens it at full size. Null when there is none.
  final VoidCallback? onOpenPicture;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final height = (MediaQuery.sizeOf(context).height * 0.42).clamp(260.0, 420.0);
    final shot = picture;
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (shot != null)
            GestureDetector(
              onTap: onOpenPicture,
              child: Image.memory(
                shot,
                fit: BoxFit.cover,
                // Drawn far larger than it was sent, so the filter is what
                // decides whether it reads as a photograph or as pixels.
                filterQuality: FilterQuality.medium,
              ),
            )
          else
            // No picture: the room's own colour across the whole cover, with
            // its initial in the middle, so the screen keeps its shape.
            Center(
              child: IdentityAvatar(
                seed: channelName,
                label: channelName,
                size: height * 0.42,
              ),
            ),
          // The name has to stay readable over whatever the picture happens to
          // be, and the buttons over the top of it likewise.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.45),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.62),
                    ],
                    stops: const [0, 0.42, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 4,
            right: 4,
            top: top + 4,
            child: Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: Colors.white,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                ),
                const Spacer(),
                if (canManage && onEdit != null)
                  IconButton(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_rounded),
                    color: Colors.white,
                    tooltip: t.channelSettingsTitle,
                  ),
              ],
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  channelName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${t.channelPrivateSubtitle} · '
                  '${t.channelMembersOf(memberCount)}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the round actions under the cover — the strip a channel carries
/// everywhere: silence it, share it, open what was posted in it.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tone,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Off-brand only where the action is: leaving a room is in the danger
  /// colour, the rest are not.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final colour = tone ?? AppColors.brandPrimary;
    return Expanded(
      child: GlassCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: colour, size: 22),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A row you open: a label, what it holds, and a chevron. The screen is a list
/// of these now rather than a page of switches.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.tone,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;

  /// The count on the right — how many members, how many administrators.
  final String? trailing;
  final Color? tone;

  /// The last row in its card draws no divider under itself.
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = tone ?? AppColors.textOnGlass;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Row(
              children: [
                Icon(icon, size: 21, color: tone ?? AppColors.textOnGlassDim),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: colour,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            color: AppColors.textOnGlassFaint,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (!last)
          Padding(
            padding: const EdgeInsets.only(left: 49),
            child: Divider(
              height: 1,
              thickness: 1,
              color: AppColors.glass(0.08),
            ),
          ),
      ],
    );
  }
}

/// A participant. Tapping opens their profile when we hold a contact for them,
/// which is the whole reason the row is a button now — a name in a member list
/// that goes nowhere is the one place people expect a profile to be.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.contact,
    required this.isMe,
    required this.canManage,
    required this.onToggleAdmin,
    required this.onInvite,
    required this.onModerate,
  });

  final ChannelMember member;
  final KnownPeer? contact;
  final bool isMe;
  final bool canManage;
  final VoidCallback onToggleAdmin;

  /// Offer this member our contact card, so they can start a conversation
  /// outside the room. See `_inviteToContacts`.
  final VoidCallback onInvite;

  /// Remove or silence them. Held down rather than given a button: the row
  /// already carries an action, moderation is the rare thing to want, and a
  /// bin beside every name is a room that looks like it expects trouble.
  final VoidCallback onModerate;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final peer = contact;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: peer == null
          ? null
          : () => context.push(
                '/person/${peer.pubkeyHex}'
                '?name=${Uri.encodeComponent(member.name)}',
              ),
      onLongPress: canManage && !isMe && !member.isAdmin ? onModerate : null,
      child: Row(
        children: [
          IdentityAvatar(
            seed: peer?.pubkeyHex ?? member.id,
            label: member.name,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  member.isMutedNow
                      ? t.channelMemberMutedNote
                      : member.isAdmin
                          ? t.channelAdministratorsTitle
                          : peer == null
                              ? t.channelMemberUnknown
                              : member.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: member.isMutedNow
                        ? AppColors.warning
                        : member.isAdmin
                            ? AppColors.brandPrimary
                            : AppColors.textOnGlassFaint,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (canManage && !isMe)
            IconButton(
              tooltip:
                  member.isAdmin ? t.channelRemoveAdmin : t.channelMakeAdmin,
              onPressed: onToggleAdmin,
              icon: Icon(
                member.isAdmin
                    ? Icons.remove_moderator_rounded
                    : Icons.add_moderator_rounded,
                color:
                    member.isAdmin ? AppColors.warning : AppColors.brandPrimary,
              ),
            )
          else if (member.isAdmin)
            Icon(Icons.verified_user_rounded, color: AppColors.brandPrimary)
          else if (peer != null)
            Icon(Icons.chevron_right_rounded,
                color: AppColors.textOnGlassFaint)
          // Somebody in the room we have never spoken to 1:1. The room shows
          // their signing fingerprint and nothing we could message, so the
          // only move available is to hand them ours.
          else if (!isMe)
            IconButton(
              tooltip: t.channelInviteToContacts,
              onPressed: onInvite,
              icon: Icon(Icons.person_add_alt_1_rounded,
                  color: AppColors.brandPrimary),
            ),
        ],
      ),
    );
  }
}
