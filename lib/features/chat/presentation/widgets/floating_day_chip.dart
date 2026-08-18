import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/utils/time_format.dart';
import '../../models/message.dart';

/// The date of whatever is at the top of the conversation, floating over it.
///
/// The separators between days already exist and stay where they are; this is
/// the one that follows you. Scroll back through a long day and the separator
/// that opened it is long gone off the top, so the only way to find out what
/// you were reading was to keep scrolling until you hit the next one.
///
/// It shows itself while the list is moving and fades out about a second after
/// it stops — a permanent chip would sit over the first message of the visible
/// range forever, which is exactly the thing anybody scrolling back is trying
/// to read.
///
/// Which message is at the top is asked of the sliver rather than computed:
/// bubbles have no common height — a one-liner, a photo, a nine-photo album —
/// so there is no offset arithmetic that would answer it. See [_topmostIndex].
class FloatingDayChip extends StatefulWidget {
  const FloatingDayChip({
    super.key,
    required this.controller,
    required this.messages,
    required this.listContext,
    this.topPadding = 0,
  });

  final ScrollController controller;

  /// Conversation order, oldest first — the same list the builder indexes.
  final List<Message> messages;

  /// Where to start looking for the sliver. The list's own context.
  final BuildContext Function() listContext;

  /// Clears the header the chip would otherwise sit under.
  final double topPadding;

  @override
  State<FloatingDayChip> createState() => _FloatingDayChipState();
}

class _FloatingDayChipState extends State<FloatingDayChip> {
  DateTime? _day;
  bool _visible = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    final index = _topmostIndex();
    if (index == null) return;
    // The builder draws `messages[length - 1 - i]`, the list being reversed.
    final at = widget.messages.length - 1 - index;
    if (at < 0 || at >= widget.messages.length) return;
    final day = widget.messages[at].sentAt;

    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _visible = false);
    });

    final sameDay = _day != null && !startsNewDay(day, _day);
    if (sameDay && _visible) return;
    setState(() {
      _day = day;
      _visible = true;
    });
  }

  /// Index of the item currently at the top of the viewport, or null.
  ///
  /// The list is reversed, so in the sliver's own coordinates the *leading*
  /// edge is the bottom of the screen and a child's main-axis position grows
  /// upward. The topmost visible child is therefore the last one still inside
  /// the paint extent — walk back from the end until one is.
  int? _topmostIndex() {
    final render = widget.listContext().findRenderObject();
    if (render == null) return null;
    final sliver = _findSliver(render);
    if (sliver == null) return null;

    final extent = sliver.constraints.remainingPaintExtent;
    var child = sliver.lastChild;
    while (child != null && sliver.childMainAxisPosition(child) >= extent) {
      child = sliver.childBefore(child);
    }
    if (child == null) return null;
    final data = child.parentData;
    return data is SliverMultiBoxAdaptorParentData ? data.index : null;
  }

  static RenderSliverMultiBoxAdaptor? _findSliver(RenderObject from) {
    RenderSliverMultiBoxAdaptor? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderSliverMultiBoxAdaptor) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(from);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    return Positioned(
      top: widget.topPadding + 6,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _visible && day != null ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Center(
            child: day == null
                ? const SizedBox.shrink()
                : Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      formatDayHeader(context, day),
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
