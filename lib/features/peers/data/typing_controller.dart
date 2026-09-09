import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'peer_activity.dart';

/// Who is doing something in a conversation right now, keyed by canonical chat
/// id (pubkey-hex).
///
/// Typing was the only thing it held, which is why it is still called this.
/// It now also carries recording a voice message and recording a circle — the
/// same shape of fact, arriving on the same frame, expiring the same way. See
/// [PeerActivity].
///
/// Memory-only for the same reason [PresenceController] is: a typing notice is
/// worth nothing a second after it arrives, let alone after a restart, and
/// persisting "who was writing to me when" is exactly the metadata this app
/// exists not to keep.
///
/// Expiry is the primary way typing *stops*. An explicit stop frame is nice
/// when it arrives, but it is the one frame most likely not to — the composer
/// is cleared by sending, the app is backgrounded mid-word, the link drops —
/// so the indicator is built to time out on its own rather than to depend on
/// being told.
class TypingController extends Notifier<Map<String, PeerActivityNotice>> {
  /// How long a typing notice is believed.
  ///
  /// Comfortably longer than [MessagingService.typingMinInterval] so a steady
  /// typist never flickers, and short enough that someone who walks away mid
  /// sentence stops "typing" while you are still looking at the screen.
  static const Duration ttl = Duration(seconds: 8);

  /// One pending removal per peer, so the map empties itself.
  ///
  /// [isTyping] alone is not enough once something *watches* this. The map only
  /// changes when a notice lands or a stop arrives, so a widget rebuilt on that
  /// map has nothing to rebuild on when the TTL merely elapses: the chat list
  /// would keep saying "typing…" under a row nobody had touched in a minute.
  /// Letting the entry remove itself makes the end of typing an event like the
  /// start of it.
  ///
  /// [isTyping] still checks the clock, and deliberately: a timer is a promise
  /// about the future, and this one is not kept while the app is suspended.
  final Map<String, Timer> _expiry = <String, Timer>{};

  @override
  Map<String, PeerActivityNotice> build() {
    ref.onDispose(_cancelAll);
    return const <String, PeerActivityNotice>{};
  }

  /// A peer started doing something. Repeated notices push the expiry out, and
  /// a different kind replaces the one showing — somebody who was typing and
  /// then held the microphone is recording, not both.
  void record(
    String canonicalId, {
    DateTime? at,
    PeerActivity kind = PeerActivity.typing,
  }) {
    final when = at ?? DateTime.now();
    state = {
      ...state,
      canonicalId: PeerActivityNotice(kind: kind, at: when),
    };
    _expiry.remove(canonicalId)?.cancel();
    // Clamped at zero rather than skipped: a notice that arrives already stale
    // — held in store-and-forward, or drained from a relay backlog — still has
    // to leave the map, and the timer firing on the next turn is what takes it
    // out. `isTyping` reports it as false meanwhile.
    final left = ttl - DateTime.now().difference(when);
    _expiry[canonicalId] = Timer(
      left.isNegative ? Duration.zero : left,
      () => _lapse(canonicalId),
    );
  }

  /// A peer said they stopped — sent when they clear the composer.
  void clear(String canonicalId) {
    _expiry.remove(canonicalId)?.cancel();
    if (!state.containsKey(canonicalId)) return;
    state = {...state}..remove(canonicalId);
  }

  void _lapse(String canonicalId) {
    _expiry.remove(canonicalId);
    if (!state.containsKey(canonicalId)) return;
    state = {...state}..remove(canonicalId);
  }

  void _cancelAll() {
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
  }

  /// What [canonicalId] is doing, or null if their last notice has lapsed.
  ///
  /// Reads the clock as well as the map, deliberately: the expiry timer is a
  /// promise about the future and it is not kept while the app is suspended,
  /// so a phone woken after an hour would otherwise find a live entry waiting.
  PeerActivity? activityOf(String canonicalId) {
    final notice = state[canonicalId];
    if (notice == null) return null;
    if (DateTime.now().difference(notice.at) >= ttl) return null;
    return notice.kind;
  }

  /// True while [canonicalId] is doing anything at all.
  bool isTyping(String canonicalId) => activityOf(canonicalId) != null;

  /// Emergency Wipe, and leaving a conversation for good.
  void clearAll() {
    _cancelAll();
    state = const <String, PeerActivityNotice>{};
  }
}

final typingControllerProvider =
    NotifierProvider<TypingController, Map<String, PeerActivityNotice>>(
  TypingController.new,
);
