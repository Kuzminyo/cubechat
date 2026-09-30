import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// A search field that becomes a round button as a list scrolls — one shape
/// the whole way, because two shapes cross-fading is what made it look like a
/// button appearing over a field disappearing rather than the field
/// *becoming* the button.
///
/// Written for Chats, whose field opens the search screen; shared since
/// Contacts wanted the same motion for a field that filters in place. So it
/// carries either a [hint] to show (a button that opens something) or a
/// [field] to type into, which is drawn while the shape is still a field.
class MorphingSearch extends StatelessWidget {
  const MorphingSearch({
    super.key,
    required this.radius,
    required this.collapse,
    required this.hint,
    required this.onTap,
    this.field,
    this.iconKey = const ValueKey('chats-header-search-button'),
  });

  final double radius;

  /// 0 a full field, 1 a round button.
  final double collapse;
  final String hint;
  final VoidCallback onTap;

  /// A text field to show instead of [hint] while this is still a field.
  final Widget? field;

  final Key iconKey;

  @override
  Widget build(BuildContext context) {
    // The words are gone well before the shape is, so they are never seen
    // being squeezed into a circle.
    final textOpacity = (1 - collapse * 2.2).clamp(0.0, 1.0);
    final field = this.field;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: AppColors.glass(0.07),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: AppColors.glass(0.12)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: lerpDouble(14, 0, collapse)!,
            ),
            child: Row(
              mainAxisAlignment: collapse > 0.5
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(
                  Icons.search_rounded,
                  key: iconKey,
                  size: 19,
                  color: AppColors.textOnGlassFaint,
                ),
                if (textOpacity > 0) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Opacity(
                      opacity: textOpacity,
                      child: field ??
                          Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            softWrap: false,
                            style: TextStyle(
                              color: AppColors.textOnGlassFaint,
                              fontSize: 14,
                            ),
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
