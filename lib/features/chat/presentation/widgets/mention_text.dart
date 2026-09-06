import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/util/debug_log.dart';
import '../../domain/message_search.dart';

/// Renders `@name` tokens and web links distinctly while preserving the message
/// verbatim.
///
/// The transport remains plain signed text, so both stay compatible with older
/// clients and searchable like any other words — nothing here changes what was
/// sent, only what it looks like and what a tap on it does.
class MentionText extends StatefulWidget {
  const MentionText(this.text, {super.key, this.highlight = '', this.fontSize});

  final String text;

  /// Overrides the body size. Only the emoji-only message uses it, and it uses
  /// it for the whole reason it exists: a message that is nothing but emoji is
  /// drawn large, the way every messenger draws one.
  ///
  /// Passed rather than read from an inherited style because everything else
  /// about the run — the link colour, the mention weight, the marked letters of
  /// a search hit — is built from [base] here, and a size arriving by a
  /// different road would have to be merged into each of them separately.
  final double? fontSize;

  /// The search query being looked at right now, or empty when none is.
  ///
  /// Marking the matched letters is the half of search that was missing: the
  /// conversation put a bar beside the message it had landed on and left the
  /// reader to find the word themselves, in a paragraph where it might appear
  /// three times or once, near the end.
  final String highlight;

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
      fontSize: widget.fontSize ?? 14.5,
      height: 1.35,
    );
    final spans = <TextSpan>[];
    var cursor = 0;

    // Where the search term sits, in offsets into this very string — computed
    // once for the whole message rather than per span, because the folding it
    // has to see through spans the whole message too.
    final marks = widget.highlight.isEmpty
        ? const <({int start, int end})>[]
        : messageHighlightRanges(widget.text, widget.highlight);

    final marked = base.copyWith(
      // A wash behind the letters rather than a colour on them: a mention is
      // already coloured and a link is already coloured and underlined, and a
      // third colour competing with those is how a highlight ends up invisible
      // on exactly the words it was asked to point at.
      //
      // Amber and opaque — see [AppColors.searchHighlight]. The first attempt
      // was the brand green at 30%, which on this green interface was a mark
      // you had to already know the position of to see.
      backgroundColor: AppColors.searchHighlight,
      color: AppColors.searchHighlightInk,
      fontWeight: FontWeight.w600,
      // A link keeps its underline; the wash must not add one of its own.
      decoration: TextDecoration.none,
    );

    /// Adds `text[start:end)` in [style], split so the matched letters carry
    /// the wash. [recognizer] is repeated on every piece, so a link stays one
    /// tap target even when the search cuts it in two.
    void add(
      int start,
      int end, {
      TextStyle? style,
      TapGestureRecognizer? recognizer,
    }) {
      if (end <= start) return;
      var at = start;
      for (final mark in marks) {
        if (mark.end <= at || mark.start >= end) continue;
        final from = mark.start < at ? at : mark.start;
        final to = mark.end > end ? end : mark.end;
        if (from > at) {
          spans.add(
            TextSpan(
              text: widget.text.substring(at, from),
              style: style,
              recognizer: recognizer,
            ),
          );
        }
        spans.add(
          TextSpan(
            text: widget.text.substring(from, to),
            style: (style ?? base).merge(marked),
            recognizer: recognizer,
          ),
        );
        at = to;
      }
      if (at < end) {
        spans.add(
          TextSpan(
            text: widget.text.substring(at, end),
            style: style,
            recognizer: recognizer,
          ),
        );
      }
    }

    for (final match in _token.allMatches(widget.text)) {
      if (match.start > cursor) {
        add(cursor, match.start);
      }
      final url = match.namedGroup('url');
      if (url != null) {
        final shown = _trimTrailing(url);
        final recognizer = TapGestureRecognizer()..onTap = () => _open(shown);
        _recognizers.add(recognizer);
        add(
          match.start,
          match.start + shown.length,
          recognizer: recognizer,
          style: base.copyWith(
            color: AppColors.brandPrimary,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.brandPrimary.withValues(alpha: 0.5),
          ),
        );
        // Whatever was trimmed is still part of the message and is drawn as
        // ordinary text, so nothing is lost between what was sent and what is
        // read.
        add(match.start + shown.length, match.end);
      } else {
        add(
          match.start,
          match.end,
          style: base.copyWith(
            color: AppColors.brandSecondary,
            fontWeight: FontWeight.w700,
          ),
        );
      }
      cursor = match.end;
    }

    add(cursor, widget.text.length);
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
