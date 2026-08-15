import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../channels/data/channel_roster_controller.dart';

class MentionSuggestions extends ConsumerWidget {
  const MentionSuggestions({
    super.key,
    required this.channelName,
    required this.text,
    required this.onTextChanged,
    required this.child,
  });

  final String channelName;
  final String text;
  final ValueChanged<String> onTextChanged;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(channelRosterControllerProvider);
    final match =
        RegExp(r'@([\p{L}\p{N}_.-]*)$', unicode: true).firstMatch(text);
    if (match == null) return child;
    final query = (match.group(1) ?? '').toLowerCase();
    final members = ref
        .read(channelRosterControllerProvider.notifier)
        .membersFor(channelName)
        .where((member) => member.name.toLowerCase().contains(query))
        .take(6)
        .toList();
    if (members.isEmpty) return child;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: members.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final member = members[index];
              return ActionChip(
                avatar: Icon(
                  member.isAdmin
                      ? Icons.verified_user_rounded
                      : Icons.alternate_email_rounded,
                  size: 15,
                  color: AppColors.brandPrimary,
                ),
                label: Text(member.name),
                onPressed: () {
                  final mention = member.name.replaceAll(RegExp(r'\s+'), '_');
                  onTextChanged('${text.substring(0, match.start)}@$mention ');
                },
              );
            },
          ),
        ),
        child,
      ],
    );
  }
}
