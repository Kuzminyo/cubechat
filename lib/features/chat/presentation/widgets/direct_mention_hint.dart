import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

/// The one-participant version of [MentionSuggestions].
///
/// A 1:1 chat has exactly one other person in it, so a roster-backed
/// autocomplete would be a list that is always one item long. This is that one
/// item: type `@`, and the name of whoever you are talking to is one tap away,
/// spelled the way [MentionText] will highlight it.
///
/// It is worth having only because typing a name by hand gets it subtly wrong
/// — a space where an underscore belongs, the broadcast name where you meant
/// the one you renamed them to — and a mention that does not match is just
/// text with an @ in front.
class DirectMentionHint extends StatelessWidget {
  const DirectMentionHint({
    super.key,
    required this.peerName,
    required this.text,
    required this.onTextChanged,
    required this.child,
  });

  /// Already alias-resolved by the caller, so the chip offers the name you
  /// actually call them rather than the one they broadcast.
  final String peerName;
  final String text;
  final ValueChanged<String> onTextChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final name = peerName.trim();
    if (name.isEmpty) return child;
    final match =
        RegExp(r'@([\p{L}\p{N}_.-]*)$', unicode: true).firstMatch(text);
    if (match == null) return child;
    final query = (match.group(1) ?? '').toLowerCase();
    // Once what has been typed no longer matches, the chip is in the way
    // rather than helpful.
    if (!name.toLowerCase().contains(query)) return child;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 42,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: ActionChip(
                avatar: Icon(
                  Icons.alternate_email_rounded,
                  size: 15,
                  color: AppColors.brandPrimary,
                ),
                label: Text(name),
                onPressed: () {
                  // Spaces become underscores for the same reason the channel
                  // version does it: the highlighter matches a single run of
                  // word characters, so "Ivan Petrov" would otherwise light up
                  // only as far as "Ivan".
                  final mention = name.replaceAll(RegExp(r'\s+'), '_');
                  onTextChanged('${text.substring(0, match.start)}@$mention ');
                },
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
