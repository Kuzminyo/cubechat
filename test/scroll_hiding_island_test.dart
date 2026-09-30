import 'package:cubechat/core/widgets/section_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The section switch's shape. Hiding it on scroll is [TabPageFrame]'s job
/// and is tested in tab_page_frame_test.dart.
void main() {
  testWidgets('the section switch is a capsule with a concentric pill',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SectionSwitch(
              labels: const ['A', 'B', 'C'],
              selected: 0,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    final height = tester.getSize(find.byType(SectionSwitch)).height;
    expect(SectionSwitch.outerRadius, height / 2);
    expect(
      SectionSwitch.pillRadius,
      SectionSwitch.outerRadius - SectionSwitch.inset,
    );
  });
}
