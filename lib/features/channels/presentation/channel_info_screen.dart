import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../data/channel_roster_controller.dart';

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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    ref.watch(channelRosterControllerProvider);
    final roster = ref.read(channelRosterControllerProvider.notifier);
    final members = roster.membersFor(widget.channelName);
    final canManage =
        _myId != null && roster.isAdmin(widget.channelName, _myId!);

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
            GlassCard(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor:
                        AppColors.brandPrimary.withValues(alpha: .2),
                    child: Icon(Icons.tag_rounded,
                        color: AppColors.brandPrimary, size: 30),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.channelName,
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${t.channelParticipantsTitle}: ${members.length}',
                          style: TextStyle(color: AppColors.textOnGlassDim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
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
              for (final member in members) ...[
                GlassCard(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: member.isAdmin
                          ? AppColors.brandPrimary.withValues(alpha: .22)
                          : AppColors.glass(.08),
                      child: Text(
                        member.name.isEmpty
                            ? '?'
                            : member.name[0].toUpperCase(),
                        style: TextStyle(color: AppColors.textOnGlass),
                      ),
                    ),
                    title: Text(
                      member.name,
                      style: TextStyle(color: AppColors.textOnGlass),
                    ),
                    subtitle: member.isAdmin
                        ? Text(
                            t.channelAdministratorsTitle,
                            style: TextStyle(color: AppColors.brandPrimary),
                          )
                        : Text(
                            member.id,
                            style: TextStyle(color: AppColors.textOnGlassFaint),
                          ),
                    trailing: canManage && member.id != _myId
                        ? IconButton(
                            tooltip: member.isAdmin
                                ? t.channelRemoveAdmin
                                : t.channelMakeAdmin,
                            onPressed: () => ref
                                .read(messagingServiceProvider)
                                .sendChannelAdminChange(
                                  widget.channelName,
                                  member.id,
                                  !member.isAdmin,
                                ),
                            icon: Icon(
                              member.isAdmin
                                  ? Icons.remove_moderator_outlined
                                  : Icons.add_moderator_outlined,
                              color: member.isAdmin
                                  ? AppColors.warning
                                  : AppColors.brandPrimary,
                            ),
                          )
                        : member.isAdmin
                            ? Icon(Icons.verified_user_rounded,
                                color: AppColors.brandPrimary)
                            : null,
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }
}
