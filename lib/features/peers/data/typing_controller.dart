import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Who is typing to us right now, keyed by canonical chat id (pubkey-hex).
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
class TypingController extends Notifier<Map<String, DateTime>> {
  /// How long a typing notice is believed.
  ///
  /// Comfortably longer than [MessagingService.typingMinInterval] so a steady
  /// typist never flickers, and short enough that someone who walks away mid
  /// sentence stops "typing" while you are still looking at the screen.
  static const Duration ttl = Duration(seconds: 8);

  @override
  Map<String, DateTime> build() => const <String, DateTime>{};

  /// A peer started typing. Repeated notices just push the expiry out.
  void record(String canonicalId, {DateTime? at}) {
    state = {...state, canonicalId: at ?? DateTime.now()};
  }

  /// A peer said they stopped — sent when they clear the composer.
  void clear(String canonicalId) {
    if (!state.containsKey(canonicalId)) return;
    state = {...state}..remove(canonicalId);
  }

  /// True while [canonicalId]'s last notice is still inside [ttl].
  bool isTyping(String canonicalId) {
    final at = state[canonicalId];
    if (at == null) return false;
    return DateTime.now().difference(at) < ttl;
  }

  /// Emergency Wipe, and leaving a conversation for good.
  void clearAll() => state = const <String, DateTime>{};
}

final typingControllerProvider =
    NotifierProvider<TypingController, Map<String, DateTime>>(
  TypingController.new,
);
