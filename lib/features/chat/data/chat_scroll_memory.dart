/// Where each conversation was left, for this run of the app.
///
/// "Scroll somewhere in a chat, leave, come back - and be in the same place;
/// back at the bottom only once the app has been closed completely" was the
/// ask. Until now every open started at the newest message.
///
/// In memory on purpose, never on disk: a position that survived closing the
/// app is exactly what was asked not to happen. And cleared when the app is
/// closed while its process lives on - on Android the engine outlives the
/// window, so memory alone would outlast a swipe from recents. See
/// `CubechatApp.didChangeAppLifecycleState`.
class ChatScrollMemory {
  ChatScrollMemory._();

  static final Map<String, double> _offsets = {};

  /// Distance from the newest message, in the list's own pixels (the list is
  /// reversed, so zero is the bottom). Nothing is kept for a chat left at the
  /// bottom: that is where it opens anyway.
  static void save(String chatId, double offset) {
    if (offset <= 1) {
      _offsets.remove(chatId);
    } else {
      _offsets[chatId] = offset;
    }
  }

  static double? of(String chatId) => _offsets[chatId];

  static void forgetAll() => _offsets.clear();
}
