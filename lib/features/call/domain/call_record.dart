import 'dart:convert';

import 'call_state_machine.dart';

/// The scheme a call record wears in a chat.
///
/// A record is written **locally by each side** and never travels: both ends
/// already know how the call ended and how long it lasted, so putting it on
/// the wire would be sending somebody a fact they already have. That is also
/// why no `InnerPayloadType` was spent on it, and why an older build can never
/// receive one it does not understand.
const String callMarker = 'cubechat:call:v1:';

/// What a chat row says about a call that has finished.
class CallRecord {
  const CallRecord({
    required this.outgoing,
    required this.answered,
    required this.talkedFor,
  });

  final bool outgoing;
  final bool answered;
  final Duration talkedFor;
}

/// The stored text for [outcome], or an empty string when the call should
/// leave no trace.
String encodeCallRecord(CallOutcome outcome) {
  // A call given up because both people dialled at once is immediately
  // replaced by the call that won. Recording both leaves two lines for one
  // conversation, which reads as a bug to the person scrolling.
  if (outcome.cause == CallEndCause.glareLost) return '';
  final answered = outcome.cause == CallEndCause.hungUp &&
      outcome.talkedFor > Duration.zero;
  final payload = <String, Object>{
    'o': outcome.outgoing,
    'a': answered,
    's': answered ? outcome.talkedFor.inSeconds : 0,
  };
  return '$callMarker${base64Url.encode(utf8.encode(jsonEncode(payload)))}';
}

/// Reads back what [encodeCallRecord] wrote, or null for anything else.
CallRecord? tryParseCallRecord(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith(callMarker)) return null;
  try {
    final raw = utf8.decode(
      base64Url.decode(trimmed.substring(callMarker.length)),
    );
    final map = jsonDecode(raw);
    if (map is! Map<String, dynamic>) return null;
    final answered = map['a'] == true;
    return CallRecord(
      outgoing: map['o'] == true,
      answered: answered,
      talkedFor: Duration(seconds: answered ? (map['s'] as int? ?? 0) : 0),
    );
  } catch (_) {
    // A record we cannot read is not a call worth guessing at.
    return null;
  }
}
