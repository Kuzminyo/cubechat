import '../../chat/models/message.dart';
import '../../chats/data/saved_messages.dart';
import 'call_record.dart';

/// How one call went, from this phone's side.
enum RecentCallKind {
  /// Somebody called and it was answered here.
  incoming,

  /// This phone called and it was answered there.
  outgoing,

  /// Somebody called and nobody answered here - the one Telegram draws red.
  missed,

  /// This phone called and nobody answered there.
  unanswered,
}

/// One line of the calls list: a call, or a run of the same kind of call to the
/// same person one after another, counted the way Telegram shows "(3)".
class RecentCall {
  const RecentCall({
    required this.peerId,
    required this.kind,
    required this.at,
    required this.count,
    required this.talkedFor,
  });

  final String peerId;
  final RecentCallKind kind;

  /// When the newest call of the run happened.
  final DateTime at;
  final int count;

  /// How long the newest call of the run lasted; zero when it was not
  /// answered.
  final Duration talkedFor;

  bool get isMissed => kind == RecentCallKind.missed;
}

/// Every call this phone remembers, newest first.
///
/// "A separate tab of recent calls, like Telegram, in Contacts" was the ask.
/// Nothing new is stored for it: each call already leaves a record in its
/// conversation (see [encodeCallRecord]), written by both sides, so the list
/// is those records gathered out of every chat. A conversation deleted takes
/// its calls with it, the same as its messages.
///
/// Channels and the notebook never hold a call and are not looked in.
List<RecentCall> recentCalls(
  Map<String, List<Message>> byChat, {
  bool missedOnly = false,
  int limit = 200,
}) {
  final found = <({String peerId, CallRecord record, DateTime at})>[];
  for (final entry in byChat.entries) {
    final chatId = entry.key;
    if (chatId.startsWith('#') || isSavedChat(chatId)) continue;
    for (final message in entry.value) {
      if (!message.text.startsWith(callMarker)) continue;
      final record = tryParseCallRecord(message.text);
      if (record == null) continue;
      found.add((peerId: chatId, record: record, at: message.sentAt));
    }
  }
  found.sort((a, b) => b.at.compareTo(a.at));

  final calls = <RecentCall>[];
  for (final call in found) {
    final kind = _kindOf(call.record);
    if (missedOnly && kind != RecentCallKind.missed) continue;
    final previous = calls.isEmpty ? null : calls.last;
    // Folded into the line above when it is the same person and the same
    // kind of call on the same day: three missed calls in a row are one
    // line that says three, not three lines that say the same thing.
    if (previous != null &&
        previous.peerId == call.peerId &&
        previous.kind == kind &&
        _sameDay(previous.at, call.at)) {
      calls[calls.length - 1] = RecentCall(
        peerId: previous.peerId,
        kind: previous.kind,
        at: previous.at,
        count: previous.count + 1,
        talkedFor: previous.talkedFor,
      );
      continue;
    }
    if (calls.length >= limit) break;
    calls.add(
      RecentCall(
        peerId: call.peerId,
        kind: kind,
        at: call.at,
        count: 1,
        talkedFor: call.record.talkedFor,
      ),
    );
  }
  return calls;
}

RecentCallKind _kindOf(CallRecord record) {
  if (record.answered) {
    return record.outgoing ? RecentCallKind.outgoing : RecentCallKind.incoming;
  }
  return record.outgoing ? RecentCallKind.unanswered : RecentCallKind.missed;
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}
