import 'package:cubechat/core/widgets/section_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a tap picks a part, and the picked one says it is selected',
      (tester) async {
    var picked = -1;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SectionSwitch(
              labels: const ['Nearby', 'AirDrop', 'Files'],
              selected: 1,
              onSelect: (i) => picked = i,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Files'));
    expect(picked, 2);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('AirDrop')),
      containsSemantics(isSelected: true, isButton: true),
    );
    expect(
      tester.getSemantics(find.text('Files')),
      containsSemantics(isSelected: false),
    );
    handle.dispose();
  });
}
