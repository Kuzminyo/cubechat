import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

/// Renders `@name` tokens distinctly while preserving the message verbatim.
/// The transport remains plain signed text, so mentions stay compatible with
/// older clients and searchable like any other words.
class MentionText extends StatelessWidget {
  const MentionText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      color: AppColors.textOnGlass,
      fontSize: 14.5,
      height: 1.35,
    );
    final spans = <TextSpan>[];
    final mention = RegExp(r'@[\p{L}\p{N}_.-]+', unicode: true);
    var cursor = 0;
    for (final match in mention.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(TextSpan(
        text: match.group(0),
        style: base.copyWith(
          color: AppColors.brandSecondary,
          fontWeight: FontWeight.w700,
        ),
      ));
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
