import 'dart:async';

import 'peer_activity.dart';

/// Keeps "sending a photo…" up on the other phone for exactly as long as
/// something is leaving this one.
///
/// The receiver believes an activity notice for `TypingController.ttl` (eight
/// seconds), and a photo over Bluetooth takes minutes, so one notice when the
/// transfer starts would lapse long before the picture landed. This repeats
/// it every [every] while anything is under way, and says stop once nothing
/// is — [linger] later, so the next photo of an album starting a moment after
/// the last one ended does not blink the line off and on.
///
/// Counted per conversation and per kind: an album is several transfers in a
/// row, and a clip can be on its way while a photo goes. While more than one
/// kind is running the most telling one is said — a video over a photo over
/// a file.
///
/// Knows nothing about the wire. [announce] and [stop] are the messaging
/// service's own notice, which already checks the privacy switch, the app
/// being in front and there being anybody to tell.
class SendingActivity {
  SendingActivity({
    required this.announce,
    required this.stop,
    this.every = const Duration(seconds: 5),
    this.linger = const Duration(milliseconds: 1500),
  });

  final void Function(String chatId, PeerActivity kind) announce;
  final void Function(String chatId) stop;
  final Duration every;
  final Duration linger;

  final Map<String, Map<PeerActivity, int>> _running = {};
  final Map<String, Timer> _pulse = {};
  final Map<String, Timer> _stopping = {};

  /// A transfer of [kind] to [chatId] started.
  void begin(String chatId, PeerActivity kind) {
    _stopping.remove(chatId)?.cancel();
    final kinds = _running.putIfAbsent(chatId, () => {});
    kinds[kind] = (kinds[kind] ?? 0) + 1;
    _say(chatId);
    _pulse[chatId] ??= Timer.periodic(every, (_) => _say(chatId));
  }

  /// One of those transfers ended — delivered, failed or abandoned alike.
  void end(String chatId, PeerActivity kind) {
    final kinds = _running[chatId];
    final count = kinds?[kind];
    if (kinds == null || count == null) return;
    if (count > 1) {
      kinds[kind] = count - 1;
      return;
    }
    kinds.remove(kind);
    if (kinds.isNotEmpty) {
      // A different kind is still going: say that one now rather than leave
      // the finished one showing until the next pulse.
      _say(chatId);
      return;
    }
    _running.remove(chatId);
    _pulse.remove(chatId)?.cancel();
    _stopping[chatId] = Timer(linger, () {
      _stopping.remove(chatId);
      if (!_running.containsKey(chatId)) stop(chatId);
    });
  }

  void _say(String chatId) {
    final kinds = _running[chatId];
    if (kinds == null || kinds.isEmpty) return;
    announce(
      chatId,
      kinds.containsKey(PeerActivity.sendingVideo)
          ? PeerActivity.sendingVideo
          : kinds.containsKey(PeerActivity.sendingPhoto)
              ? PeerActivity.sendingPhoto
              : PeerActivity.sendingFile,
    );
  }

  /// Everything cancelled, nothing said.
  void dispose() {
    for (final timer in [..._pulse.values, ..._stopping.values]) {
      timer.cancel();
    }
    _pulse.clear();
    _stopping.clear();
    _running.clear();
  }
}
