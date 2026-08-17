import '../../../core/transport/shared_contact.dart';
import '../../../core/transport/shared_location.dart';
import '../../../l10n/app_localizations.dart';
import '../../map/data/map_friend_link.dart';
import '../models/message.dart';

/// One line standing in for a message somewhere the message itself cannot be
/// drawn: a row in the chat list, a quoted reply, a system notification.
///
/// It exists because [Message.text] is not always words. A photo carries its
/// mime type there, a sticker carries its marker, and both were reaching the
/// screen raw — rows reading `cubechat:sticker:v1`, notifications announcing
/// `image/jpeg`. Every place that shows a message it cannot render asks this
/// instead, so there is one answer to "what do you call this" and it is in one
/// place.
///
/// A sticker is named by the emoji it was filed under, which is the only name
/// it has; see [Message.stickerMarkerFor].
String messagePreview(Message message, AppLocalizations t) {
  if (message.isSticker) {
    final emoji = message.stickerEmoji;
    return emoji == null ? t.stickerLabel : '$emoji ${t.stickerLabel}';
  }
  switch (message.kind) {
    case MessageKind.image:
      // A caption is a better preview than the word "photo", when there is one.
      final caption = message.imageCaption;
      return caption == null || caption.isEmpty
          ? '📷 ${t.previewPhoto}'
          : '📷 $caption';
    case MessageKind.audio:
      return '🎤 ${t.previewVoice}';
    case MessageKind.file:
      final name = message.fileName;
      return '📎 ${name == null || name.isEmpty ? t.previewFile : name}';
    case MessageKind.poll:
      return '📊 ${message.text}';
    case MessageKind.text:
      return _textPreview(message.text, t);
  }
}

/// Words, or the name of whatever is riding inside them.
///
/// Three kinds of thing travel as text in this app — a position, a contact
/// card, an invitation to the map — because riding inside a message gets them
/// encryption, signing, replies and forwarding for free (see [SharedLocation]).
/// The cost is that anything showing a message *as text* shows the payload, and
/// a chat row reading `cubechat:loc:v1:NTAuMDQxMDM…` is what that looks like.
///
/// Named rather than hidden: the row has to say something happened, and "a
/// location" is the true and useful thing to say.
String _textPreview(String text, AppLocalizations t) {
  final trimmed = text.trim();
  // Cheap gate first — every one of these starts with the same scheme, and
  // almost no message does.
  if (!trimmed.startsWith('cubechat:')) return text;
  if (SharedLocation.tryParse(trimmed) != null) return '📍 ${t.previewLocation}';
  if (MapFriendLink.tryParse(trimmed) != null) return '🗺 ${t.previewMapInvite}';
  if (SharedContact.tryParse(trimmed) != null) return '👤 ${t.previewContact}';
  // An unknown `cubechat:` payload — a newer build's, most likely. Saying so is
  // better than showing base64 at somebody.
  return t.previewUnsupported;
}

/// The same, for a row that kept only the text of the message.
///
/// Less can be said from a string than from the message it came out of — a
/// mime type is indistinguishable from somebody typing "image/jpeg" — so this
/// answers for the one case that is unambiguous and hands everything else back
/// untouched. Prefer [messagePreview] wherever the message itself is still to
/// hand.
String storedTextPreview(String stored, AppLocalizations t) {
  final trimmed = stored.trim();
  if (!trimmed.startsWith(Message.stickerMarker)) return stored;
  final rest = trimmed.substring(Message.stickerMarker.length);
  final emoji = rest.startsWith(':') ? rest.substring(1).trim() : '';
  return emoji.isEmpty ? t.stickerLabel : '$emoji ${t.stickerLabel}';
}
