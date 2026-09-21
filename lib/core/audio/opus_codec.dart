/// The Opus codec for voice notes, wherever the app runs.
///
/// libopus is reached through `dart:ffi`, which the web build does not have —
/// and the web build is kept for working on the interface. Import this, not
/// `opus_voice.dart`, from anything the app itself uses.
library;

export 'opus_voice_unsupported.dart'
    if (dart.library.ffi) 'opus_voice.dart';
