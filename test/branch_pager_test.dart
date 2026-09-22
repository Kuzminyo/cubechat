import 'package:cubechat/core/routing/branch_pager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // One slot used to hold the only pager, the chats list's. A second branch
  // with pages would have overwritten it, and the folders would have stopped
  // taking the swipe until the chats list happened to rebuild.
  test('each branch keeps its own pager', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final slot = c.read(branchPagersProvider.notifier);
    registerBranchPager(
      slot,
      BranchPager(branch: kChatsBranch, index: 0, count: 4, step: (_) {}),
    );
    registerBranchPager(
      slot,
      BranchPager(branch: kNearbyBranch, index: 1, count: 3, step: (_) {}),
    );
    registerBranchPager(
      slot,
      BranchPager(branch: kNearbyBranch, index: 2, count: 3, step: (_) {}),
    );
    final pagers = c.read(branchPagersProvider);
    expect(pagers[kChatsBranch]?.count, 4);
    expect(pagers[kNearbyBranch]?.index, 2);
    expect(pagers[kNearbyBranch]!.canStep(1), isFalse);
    expect(pagers[kNearbyBranch]!.canStep(-1), isTrue);
  });
}
