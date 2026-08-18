import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How far along an outgoing photo or voice note is, keyed by message id.
///
/// A picture leaves as a manifest and then a few hundred chunks, and over
/// Bluetooth that is minutes. Until now the bubble said only "sending" for all
/// of it and then flipped to a tick, so there was no way to tell a transfer
/// that was crawling from one that had stalled — "чтобы понимать когда файл или
/// фотка дойдет" is that gap.
///
/// Files already had this ([FileTransferTask.progress]); media did not, because
/// media does not go through the transfer queue. Rather than push photos into
/// that queue — it persists tasks, retries them and has a screen of its own,
/// none of which a photo wants — this is the one number the bubble needs.
///
/// Session state, not persisted. A transfer does not survive the process, so
/// neither should its progress bar.
class MediaSendProgressController extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const <String, double>{};

  /// Report [sent] of [total] chunks for [messageId].
  ///
  /// Quantised to whole percent before it touches state. A photo over BLE is
  /// ~300 chunks and this is called on every one of them; writing the map each
  /// time would rebuild the conversation three hundred times to move a ring by
  /// a third of a degree, which is precisely the kind of per-frame work the
  /// Diagnostics panel keeps catching.
  void report(String messageId, {required int sent, required int total}) {
    if (total <= 0) return;
    final next = (sent / total).clamp(0.0, 1.0);
    final current = state[messageId];
    if (current != null && (next * 100).floor() == (current * 100).floor()) {
      return;
    }
    state = {...state, messageId: next};
  }

  /// Done, failed, or abandoned — either way the ring goes away.
  void clear(String messageId) {
    if (!state.containsKey(messageId)) return;
    state = {...state}..remove(messageId);
  }
}

final mediaSendProgressProvider =
    NotifierProvider<MediaSendProgressController, Map<String, double>>(
  MediaSendProgressController.new,
);
