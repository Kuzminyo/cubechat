import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The conversation between its two floating islands, laid out in one pass.
///
/// The header at the top and the composer at the bottom are measured first,
/// and the list is given exactly the room between them — in the same layout,
/// so whatever changes either island's height moves the conversation with it
/// on the same frame.
///
/// It used to be a Stack with the list's padding taken from the islands'
/// heights, measured *after* each frame and applied with a setState. Every
/// change of height was therefore drawn once wrong: the reply bar appearing,
/// a sent message emptying a three-line composer, the keyboard's own slot
/// settling — each put the newest message under the composer (or a gap above
/// it) for a frame, then snapped. "Everything jumps — sending, the keyboard
/// coming and going, replying" (2026-10-15).
///
/// The list still runs behind both islands: it is expected to paint past its
/// own box (`clipBehavior: Clip.none`), and its cache extent reaches well
/// beyond either island, so the conversation shows through the glass as it
/// always did.
class ChatIslandsLayout extends StatelessWidget {
  const ChatIslandsLayout({
    super.key,
    required this.list,
    required this.header,
    required this.composer,
    this.button,
    this.buttonGap = 20,
  });

  final Widget list;
  final Widget header;
  final Widget composer;

  /// Sits [buttonGap] above the composer's top, at the right edge.
  final Widget? button;
  final double buttonGap;

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(
      delegate: _IslandsDelegate(buttonGap),
      // Paint order is child order: the conversation underneath, the islands
      // over it, the composer last.
      children: [
        LayoutId(id: _Slot.list, child: list),
        LayoutId(id: _Slot.header, child: header),
        if (button != null) LayoutId(id: _Slot.button, child: button!),
        LayoutId(id: _Slot.composer, child: composer),
      ],
    );
  }
}

enum _Slot { list, header, button, composer }

class _IslandsDelegate extends MultiChildLayoutDelegate {
  _IslandsDelegate(this.buttonGap);

  final double buttonGap;

  @override
  void performLayout(Size size) {
    // Full width, unbounded height: what a Stack hands a child pinned to one
    // edge, which is how both islands were placed before and what their
    // columns are built to size themselves under.
    final width = BoxConstraints(minWidth: size.width, maxWidth: size.width);
    final header = layoutChild(_Slot.header, width);
    positionChild(_Slot.header, Offset.zero);
    final composer = layoutChild(_Slot.composer, width);
    final composerTop = size.height - composer.height;
    positionChild(_Slot.composer, Offset(0, composerTop));

    final listHeight = math.max(0.0, composerTop - header.height);
    layoutChild(
      _Slot.list,
      BoxConstraints.tight(Size(size.width, listHeight)),
    );
    positionChild(_Slot.list, Offset(0, header.height));

    if (hasChild(_Slot.button)) {
      final button = layoutChild(_Slot.button, const BoxConstraints());
      positionChild(
        _Slot.button,
        Offset(
          size.width - 16 - button.width,
          composerTop - buttonGap - button.height,
        ),
      );
    }
  }

  @override
  bool shouldRelayout(_IslandsDelegate old) => old.buttonGap != buttonGap;
}
