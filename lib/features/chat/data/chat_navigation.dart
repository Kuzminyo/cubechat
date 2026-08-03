import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A request to scroll the open conversation to one message.
///
/// A provider rather than a callback threaded down the tree: the things that
/// want to jump — a tapped quote, the pinned bar, a search result — sit at
/// different depths, and the scroll controller belongs to the list. Set the
/// wire id and whoever owns the list answers.
///
/// Keyed by chat, so a request left behind by one conversation cannot fire in
/// the next one.
final chatJumpRequestProvider =
    StateProvider.family<String?, String>((ref, chatId) => null);

/// The message to flash after arriving.
///
/// Landing somewhere in the middle of a scrollback with no indication of which
/// line you were sent to is the reason jumping felt broken: the screen moves
/// and nothing says why. Held by message id — not wire id — because that is
/// what a bubble knows about itself without a lookup.
final chatHighlightProvider =
    StateProvider.family<String?, String>((ref, chatId) => null);
