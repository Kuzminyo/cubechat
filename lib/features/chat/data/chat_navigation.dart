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

/// What the search bar of this conversation currently holds, so the bubbles
/// can mark the letters that answered it.
///
/// A provider for the same reason as the two above: the query is typed in the
/// header and needed at the bottom of every bubble's text, and the path
/// between them runs through the album grouping, the reply quote and the
/// selection wrapper — none of which have any business carrying a search term.
///
/// Empty, never null: "no search" and "searched for nothing" are the same
/// thing to everyone reading it, and one of them would need a null check at
/// every use.
final chatSearchQueryProvider =
    StateProvider.family<String, String>((ref, chatId) => '');
