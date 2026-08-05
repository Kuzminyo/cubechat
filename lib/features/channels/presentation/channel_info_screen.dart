import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/inner_payload.dart';
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

  Future<void> _pickChannelAvatar() async {
    final t = AppLocalizations.of(context);
    final result = await showGlassSheet<MediaPickerResult>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const MediaPickerSheet(allowFiles: false),
    );
    if (result is! MediaPickerAssets || result.assets.isEmpty) return;

    final preview = await result.assets.first.thumbnailDataWithSize(
      const ThumbnailSize(1024, 1024),
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
      maxBytes: AvatarPayload.maxBytes,
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
    final canManage =
        _myId != null && roster.isAdmin(widget.channelName, _myId!);
    final picture =
        ref.watch(channelAvatarsControllerProvider)[widget.channelName];
    final contacts = _byFingerprint(ref.watch(knownPeersControllerProvider));

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: AppColors.textOnGlass,
          title: Text(t.channelInfoTitle),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _ChannelHero(
              channelName: widget.channelName,
              memberCount: members.length,
              picture: picture,
              // The tap does nothing for a member rather than offering a
              // picker that would be refused on arrival — and the toast says
              // which, so a disabled control is never a mystery.
              onTapAvatar: canManage
                  ? _pickChannelAvatar
                  : () => showGlassToast(context, t.channelAvatarAdminOnly),
              onRemoveAvatar:
                  canManage && picture != null ? _removeChannelAvatar : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ChannelAction(
                    icon: Icons.person_add_alt_1_outlined,
                    label: t.channelInviteTitle,
                    onTap: () =>
                        showChannelInviteSheet(context, widget.channelName),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ChannelAction(
                    icon: Icons.perm_media_outlined,
                    label: t.channelSharedContent,
                    // The channel's own bucket keys the shared-content screen
                    // exactly the way a peer's pubkey does, so the media, files
                    // and polls tabs come for free.
                    onTap: () => context.push(
                      '/person/${Uri.encodeComponent(widget.channelName)}'
                      '/content?name=${Uri.encodeComponent(widget.channelName)}',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              t.channelParticipantsTitle.toUpperCase(),
              style: TextStyle(
                color: AppColors.textOnGlassDim,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            if (members.isEmpty)
              GlassCard(
                child: Text(
                  t.channelNoParticipants,
                  style: TextStyle(color: AppColors.textOnGlassDim),
                ),
              )
            else
              for (final member in members)
                _MemberRow(
                  member: member,
                  contact: contacts[member.id],
                  isMe: member.id == _myId,
                  canManage: canManage,
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
}

/// The card the screen opens on: the room's picture, its name, and how many
/// people are in it.
///
/// Replaces a row that showed a megaphone glyph for every channel there has
/// ever been — which told you nothing about *this* one, and made two rooms
/// indistinguishable at a glance in the one place that exists to tell them
/// apart.
class _ChannelHero extends StatelessWidget {
  const _ChannelHero({
    required this.channelName,
    required this.memberCount,
    required this.picture,
    required this.onTapAvatar,
    required this.onRemoveAvatar,
  });

  final String channelName;
  final int memberCount;
  final Uint8List? picture;
  final VoidCallback onTapAvatar;
  final VoidCallback? onRemoveAvatar;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      child: Column(
        children: [
          GestureDetector(
            onTap: onTapAvatar,
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                IdentityAvatar(
                  seed: channelName,
                  label: channelName,
                  size: 96,
                  imageBytes: picture,
                  mark: picture == null ? Icons.campaign_rounded : null,
                ),
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandPrimary,
                  ),
                  child: const Icon(
                    Icons.photo_camera_rounded,
                    size: 14,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            channelName,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 21,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${t.channelParticipantsTitle}: $memberCount',
            style: TextStyle(color: AppColors.textOnGlassDim),
          ),
          if (onRemoveAvatar != null)
            TextButton(
              onPressed: onRemoveAvatar,
              child: Text(
                t.avatarRemove,
                style: TextStyle(color: AppColors.warning),
              ),
            ),
        ],
      ),
    );
  }
}

/// One of the two big buttons under the hero.
class _ChannelAction extends StatelessWidget {
  const _ChannelAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon, color: AppColors.brandPrimary, size: 22),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textOnGlass, fontSize: 12.5),
          ),
        ],
      ),
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
  });

  final ChannelMember member;
  final KnownPeer? contact;
  final bool isMe;
  final bool canManage;
  final VoidCallback onToggleAdmin;

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
                  member.isAdmin
                      ? t.channelAdministratorsTitle
                      : peer == null
                          ? t.channelMemberUnknown
                          : member.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: member.isAdmin
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
                    ? Icons.remove_moderator_outlined
                    : Icons.add_moderator_outlined,
                color:
                    member.isAdmin ? AppColors.warning : AppColors.brandPrimary,
              ),
            )
          else if (member.isAdmin)
            Icon(Icons.verified_user_rounded, color: AppColors.brandPrimary)
          else if (peer != null)
            Icon(Icons.chevron_right_rounded,
                color: AppColors.textOnGlassFaint),
        ],
      ),
    );
  }
}
