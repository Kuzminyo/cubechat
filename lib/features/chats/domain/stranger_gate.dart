import '../../../core/transport/inner_payload.dart';
import '../../profile/data/privacy_settings_controller.dart';

/// What to do with a message from somebody who is not a contact.
///
/// Only internet arrivals are gated: a phone cannot tell a stranger who found
/// our @name from one who got our QR card — both arrive over Nostr from an
/// unknown key — while a Bluetooth neighbour is, by definition, standing
/// here. A "contact" is someone we have written to, or whose request we
/// accepted. A request already waiting stays a request whatever the setting
/// says now, so switching to "nobody" never silently deletes it.
enum StrangerVerdict { deliver, request, drop }

StrangerVerdict strangerVerdict({
  required StrangerReach reach,
  required bool viaInternet,
  required bool wroteToThem,
  required bool accepted,
  required bool alreadyPending,
}) {
  if (!viaInternet || wroteToThem || accepted) return StrangerVerdict.deliver;
  if (alreadyPending) return StrangerVerdict.request;
  return switch (reach) {
    StrangerReach.all => StrangerVerdict.deliver,
    StrangerReach.request => StrangerVerdict.request,
    StrangerReach.none => StrangerVerdict.drop,
  };
}

/// Whether a frame of [type] from a stranger opens a request.
///
/// Only what a person sends: a message, media, a call, a channel invite.
/// Receipts, typing, presence and reactions must not — a stranger's read
/// receipt is not a conversation. A type added later answers false until
/// somebody decides otherwise here; that is the safe side.
bool opensRequest(InnerPayloadType type) => switch (type) {
      InnerPayloadType.text ||
      InnerPayloadType.textReply ||
      InnerPayloadType.mediaManifest ||
      InnerPayloadType.imageChunk ||
      InnerPayloadType.audioChunk ||
      InnerPayloadType.fileChunk ||
      InnerPayloadType.callSignal ||
      InnerPayloadType.channelInvite =>
        true,
      _ => false,
    };
