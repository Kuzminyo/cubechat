import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Media held on the relays until a cheaper network, counted per chat.
///
/// Written by `MessagingService` while "wait for Wi-Fi" has the media inbox
/// paused: the manifest of each photo, voice note, circle or file has arrived,
/// its chunks have not been fetched. Empty whenever nothing is being held, so
/// a row that reads from it disappears on its own.
final heldMediaProvider = StateProvider<Map<String, int>>((_) => const {});
