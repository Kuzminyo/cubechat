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

/// A request to go to the first message of one day.
///
/// The floating date is the only thing on the screen that knows where you are
/// in a long scrollback, and it was the one thing you could not touch. Tapping
/// it now goes to the top of the day it names — which is the gesture people
/// try on it anyway, because it looks like a control.
///
/// Held as a day rather than a message id: the chip knows the date, and which
/// message begins it is the conversation's business to work out, freshly, at
/// the moment of the tap.
final chatJumpToDayProvider =
    StateProvider.family<DateTime?, String>((ref, chatId) => null);

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
