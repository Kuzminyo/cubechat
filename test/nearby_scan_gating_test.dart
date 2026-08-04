import 'package:cubechat/core/routing/branch_container.dart';
import 'package:cubechat/core/util/app_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Nearby tab drops the BLE scanner to the idle cadence whenever nobody is
/// looking at it, which is what keeps an Android phone from holding the radio
/// at a 71% duty cycle while the user reads a conversation.
///
/// That rests on one assumption about the tab shell: every branch stays mounted
/// for the whole session, so the screen cannot use initState/dispose to know
/// whether it is on screen — it reads [TickerMode] instead. These tests pin the
/// assumption down against the real [BranchContainer], because if the shell
/// ever stops disabling TickerMode for offstage branches the gating fails
/// silently and the only symptom is a warm phone.
void main() {
  /// Records what TickerMode reports, the same way the Nearby screen does.
  Widget probe(List<bool> log) => Builder(
        builder: (context) {
          log.add(TickerMode.of(context));
          return const SizedBox.shrink();
        },
      );

  testWidgets('an offstage branch is told its tickers are muted',
      (tester) async {
    final active = <bool>[];
    final inactive = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: BranchContainer(
          currentIndex: 0,
          branches: [probe(active), probe(inactive)],
          onSwitch: (_) {},
        ),
      ),
    );

    expect(active.last, isTrue, reason: 'the visible branch runs tickers');
    expect(inactive.last, isFalse,
        reason: 'an offstage branch must report muted, or Nearby would keep '
            'scanning at the active cadence from behind another tab');
  });

  testWidgets('switching tabs flips which branch reports itself watched',
      (tester) async {
    final first = <bool>[];
    final second = <bool>[];

    Widget shell(int index) => MaterialApp(
          home: BranchContainer(
            currentIndex: index,
            branches: [probe(first), probe(second)],
            onSwitch: (_) {},
          ),
        );

    await tester.pumpWidget(shell(0));
    expect(first.last, isTrue);
    expect(second.last, isFalse);

    await tester.pumpWidget(shell(1));
    await tester.pumpAndSettle();

    expect(first.last, isFalse,
        reason: 'leaving Nearby has to release the active cadence');
    expect(second.last, isTrue);
  });

  test('nothing is watching Nearby until a screen says so', () {
    // The flag is a process-wide singleton, so its resting state is what a
    // freshly launched (or backgrounded) app scans at.
    expect(AppLifecycle.instance.isWatchingNearby, isFalse);
  });
}
