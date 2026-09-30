import 'package:flutter/widgets.dart';

/// How far down a page under a [TabPageFrame] has to start its list, so its
/// first row sits below the header and the section switch drawn over it
/// rather than under them.
///
/// Zero where there is no frame, so a page reads it unconditionally.
class IslandInset extends InheritedWidget {
  const IslandInset({super.key, required this.height, required super.child});

  final double height;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IslandInset>()?.height ?? 0;

  @override
  bool updateShouldNotify(IslandInset old) => old.height != height;
}
