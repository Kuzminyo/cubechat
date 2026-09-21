import 'ogg_opus.dart';

/// What a voice note is encoded as.
///
/// Telegram's `audio.c`: 48 kHz, mono, `OPUS_APPLICATION_VOIP`, 960-sample
/// (20 ms) frames. The one number that differs is the rate. Theirs asks for
/// `OPUS_BITRATE_MAX` and lets the variable rate find its level; ours is held
/// to 32 kbps, because every byte of a note crosses Bluetooth at about 14 KB/s
/// when there is no internet. Opus at 32 kbps on speech is past what AAC did
/// at 64 — which is what this replaced — at half the airtime: 240 KB a minute
/// against 480.
abstract final class OpusVoice {
  static const int sampleRate = OggOpus.granuleRate;
  static const int channels = 1;
  static const int frameSamples = 960; // 20 ms at 48 kHz
  static const int bitRate = 32000;

  /// Largest packet libopus may write for one frame — its own recommended
  /// ceiling, far above anything 32 kbps produces.
  static const int maxPacketBytes = 4000;

  /// A decoded frame can be up to 120 ms.
  static const int maxFrameSamples = 5760;

  /// The mime type on the wire. The receiving side already names these
  /// `.opus`, and Android's player opens them natively.
  static const String mime = 'audio/ogg';

  static bool isOpusMime(String? mime) {
    final m = mime?.toLowerCase() ?? '';
    return m.startsWith('audio/ogg') || m.startsWith('audio/opus');
  }
}
