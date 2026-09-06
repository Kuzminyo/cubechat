import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A branch that has pages of its own to flip through before the strip moves.
///
/// The tab strip owns the horizontal drag for the whole shell, and until now
/// that was the only thing a sideways flick could mean. The chats list has a
/// second row of things underneath it — All, then the built-in folders, then
/// the ones the user made — and reaching them meant aiming at a pill. Telegram
/// flips those with the same gesture that changes tab, and stepping off the end
/// of the folders is what takes you to the next tab; asked for in those words.
///
/// Registered by the branch rather than known by the shell, because the shell
/// has no business knowing what a chats list keeps in its header. It publishes
/// three facts — how many stops there are, which one it is on, and how to move
/// — and the strip asks before it decides a drag was about tabs.
class BranchPager {
  const BranchPager({
    required this.branch,
    required this.index,
    required this.count,
    required this.step,
  });

  /// Which shell branch this belongs to.
  ///
  /// Carried because the shell keeps every branch mounted for the life of the
  /// app, so a registration is never taken down by a screen going away — the
  /// chats list is alive the whole time somebody is reading their profile. The
  /// strip checks this against the tab actually showing, or the folders would
  /// eat a sideways flick on every other screen in the app.
  final int branch;

  /// Which stop is showing, from 0.
  final int index;

  /// How many stops there are. One means there is nothing to flip.
  final int count;

  /// Move by [delta] stops. Called only when [canStep] agrees.
  final void Function(int delta) step;

  /// Whether a flick this way lands on another stop rather than another tab.
  ///
  /// The edges are where the strip takes over, and that is the whole feel of
  /// it: the folders run out, and the next flick is a tab. Nothing rubber-bands
  /// and nothing is swallowed.
  bool canStep(int delta) {
    final next = index + delta;
    return next >= 0 && next < count;
  }
}

/// The pager a branch has published, or null while nothing has one.
///
/// A single slot rather than one per branch, because only one branch has ever
/// wanted this. It is not cleared when that branch leaves the screen and does
/// not need to be: [branch] says who it belongs to, and the strip only asks
/// when that tab is the one showing.
final branchPagerProvider = StateProvider<BranchPager?>((ref) => null);

/// The chats branch, as declared in `app_router.dart`.
///
/// Named rather than written as 0 at the two ends that have to agree — the
/// screen that publishes a pager and the strip that decides whether to ask it.
const int kChatsBranch = 0;
