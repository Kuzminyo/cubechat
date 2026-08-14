import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/util/debug_log.dart';

/// Renders `@name` tokens and web links distinctly while preserving the message
/// verbatim.
///
/// The transport remains plain signed text, so both stay compatible with older
/// clients and searchable like any other words — nothing here changes what was
/// sent, only what it looks like and what a tap on it does.
class MentionText extends StatefulWidget {
  const MentionText(this.text, {super.key});

  final String text;

  @override
  State<MentionText> createState() => _MentionTextState();
}

class _MentionTextState extends State<MentionText> {
  /// One per link on screen, and every one of them has to be disposed —
  /// a recognizer left behind holds the span, the state and the callback.
  final _recognizers = <TapGestureRecognizer>[];

  /// Schemes only, plus the `www.` that everybody types instead. Deliberately
  /// not "anything with a dot in it": that turns `фото.jpg`, `1.5` and a
  /// sentence written without a space after the full stop into links, and a
  /// message is mostly prose.
  static final _token = RegExp(
    r'(?<url>(?:https?://|www\.)[^\s<>"«»]+)|(?<mention>@[\p{L}\p{N}_.-]+)',
    unicode: true,
    caseSensitive: false,
  );

  /// Sentence punctuation that followed the link rather than belonging to it.
  /// A closing bracket only counts as trailing when nothing opened it inside
  /// the link — Wikipedia addresses really do end in one.
  static String _trimTrailing(String url) {
    var end = url.length;
    while (end > 0) {
      final c = url[end - 1];
      if ('.,;:!?»"\''.contains(c)) {
        end--;
      } else if (c == ')' &&
          !url.substring(0, end).contains('(')) {
        end--;
      } else {
        break;
      }
    }
    return url.substring(0, end);
  }

  Future<void> _open(String shown) async {
    final uri = Uri.tryParse(
      shown.startsWith('www.') ? 'https://$shown' : shown,
    );
    if (uri == null) return;
    try {
      // Externally, not in a web view: a link somebody taps in a chat belongs
      // in the browser they chose, with their sessions, their extensions and
      // their history — and out of an app that promises not to be a window
      // onto the web.
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      DebugLog.instance.log('LINK', 'could not open $uri: $e');
    }
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final base = TextStyle(
      color: AppColors.textOnGlass,
      fontSize: 14.5,
      height: 1.35,
    );
    final spans = <TextSpan>[];
    var cursor = 0;

    for (final match in _token.allMatches(widget.text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      final url = match.namedGroup('url');
      if (url != null) {
        final shown = _trimTrailing(url);
        final recognizer = TapGestureRecognizer()..onTap = () => _open(shown);
        _recognizers.add(recognizer);
        spans.add(TextSpan(
          text: shown,
          recognizer: recognizer,
          style: base.copyWith(
            color: AppColors.brandPrimary,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.brandPrimary.withValues(alpha: 0.5),
          ),
        ));
        // Whatever was trimmed is still part of the message and is drawn as
        // ordinary text, so nothing is lost between what was sent and what is
        // read.
        if (shown.length < url.length) {
          spans.add(TextSpan(text: url.substring(shown.length)));
        }
      } else {
        spans.add(TextSpan(
          text: match.group(0),
          style: base.copyWith(
            color: AppColors.brandSecondary,
            fontWeight: FontWeight.w700,
          ),
        ));
      }
      cursor = match.end;
    }

    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
