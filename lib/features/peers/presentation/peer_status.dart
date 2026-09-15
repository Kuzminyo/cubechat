import 'package:flutter/material.dart';

import '../../../core/utils/time_format.dart';
import '../../../l10n/app_localizations.dart';
import '../data/peer_activity.dart';

/// The words for what somebody is doing right now.
///
/// One place, because three screens say it — the chat header, the chat list
/// row and the peek — and each had its own copy of the same switch. A new
/// activity added to one of them and not the others is a person who is
/// "sending a photo…" in the list and says nothing at all in the header.
String peerActivityLabel(AppLocalizations t, PeerActivity activity) =>
    switch (activity) {
      PeerActivity.typing => t.chatTyping,
      PeerActivity.recordingVoice => t.chatRecordingVoice,
      PeerActivity.recordingCircle => t.chatRecordingCircle,
      PeerActivity.sendingPhoto => t.chatSendingPhoto,
      PeerActivity.sendingVideo => t.chatSendingVideo,
      PeerActivity.sendingFile => t.chatSendingFile,
    };

/// The mark beside [peerActivityLabel], where there is room for one.
///
/// Still, not animated. Telegram's dots move; here the row that carries this
/// is one of dozens in a scrolling list, and a ticker per row for as long as
/// somebody records is the kind of always-on frame cost this app has spent
/// several builds removing. The words already say it is happening now.
IconData peerActivityIcon(PeerActivity activity) => switch (activity) {
      PeerActivity.typing => Icons.edit_rounded,
      PeerActivity.recordingVoice => Icons.mic_rounded,
      PeerActivity.recordingCircle => Icons.radio_button_checked_rounded,
      PeerActivity.sendingPhoto => Icons.photo_rounded,
      PeerActivity.sendingVideo => Icons.videocam_rounded,
      PeerActivity.sendingFile => Icons.insert_drive_file_rounded,
    };

/// A live activity as the list and the peek draw it: its mark, then its words,
/// in one colour, on one line.
class PeerActivityLine extends StatelessWidget {
  const PeerActivityLine({
    super.key,
    required this.activity,
    required this.style,
    this.iconSize = 14,
  });

  final PeerActivity activity;
  final TextStyle style;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(peerActivityIcon(activity), size: iconSize, color: style.color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            peerActivityLabel(t, activity),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// The one line under a person's name: blocked, connecting, doing something,
/// online, or when they were last here.
///
/// Shared by the chat header and the peek, which is a look at the same
/// conversation and used to say less about the same person — online or
/// nothing, so somebody away for a week and somebody away for a minute read
/// the same.
///
/// In this order, and each step is a decision:
///
///  * **Blocked** first. Nothing this person's phone says about itself is
///    worth repeating once you have blocked them; their beacons are dropped on
///    arrival, so a last-seen shown here froze at the moment of the block and
///    grew staler by the day.
///  * **[sessionNote]** next — a handshake in progress or a failed one, which
///    only the chat header has to say.
///  * **[activity]** ahead of online: somebody doing any of these is online by
///    definition, and the more specific fact is the one worth the line.
///  * **Online.**
///  * **Recently** when times are hidden — ours, because we stopped publishing
///    our own, or theirs, carried on their beacon. Still "online" above when
///    they are: that is a fact about now, not a history.
///  * **[lastPresent]**, the last time they were in the app rather than the
///    last time their phone spoke — see `KnownPeer.lastPresenceAt` and
///    [formatLastSeen] for the three ways of saying it.
///  * **Offline**, with no time, when there is none to give.
String peerStatusLine(
  BuildContext context, {
  required bool blocked,
  String? sessionNote,
  PeerActivity? activity,
  required bool online,
  required bool hideTimes,
  DateTime? lastPresent,
}) {
  final t = AppLocalizations.of(context);
  if (blocked) return t.chatBlockedStatus;
  if (sessionNote != null) return sessionNote;
  if (activity != null) return peerActivityLabel(t, activity);
  if (online) return t.presenceOnline;
  if (hideTimes) return t.presenceRecently;
  if (lastPresent != null) return formatLastSeen(context, lastPresent);
  return t.presenceOffline;
}
