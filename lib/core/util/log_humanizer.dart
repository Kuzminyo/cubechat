import 'package:flutter/foundation.dart';

import '../../l10n/app_localizations.dart';

/// What part of the app a log line is about, as somebody using it would
/// group things.
enum LogKind {
  startup,
  internet,
  bluetooth,
  chats,
  media,
  calls,
  location,
  backup,
  problem,
}

/// One log line as the Diagnostics screen shows it to somebody who is not
/// debugging the app.
@immutable
class FriendlyLogLine {
  const FriendlyLogLine({required this.kind, required this.text});

  final LogKind kind;
  final String text;
}

/// The Diagnostics log, for somebody who is not the developer.
///
/// "Make the logs simpler for an ordinary user, they are so complicated, not
/// needed" was the ask. The raw log is thousands of lines of relay publishes,
/// receipts, frame timings and crypto steps — every one of them worth having
/// in the file sent to the developer, and none of them something a person
/// looking at their own phone can do anything with. So this keeps what they
/// would recognise — the app starting, the internet connection coming and
/// going, chats, files, calls, Bluetooth, and anything that failed — says the
/// common ones in their language, and leaves the rest to "Technical records"
/// and to the shared file, which stays complete.
///
/// Returns null for a line that is not worth showing here.
FriendlyLogLine? humanizeLogLine(String line, AppLocalizations t) {
  final match = _tagged.firstMatch(line);
  final tag = match?.group(1);
  final body = (match?.group(2) ?? line).trim();

  // The relay says these all day and none of them is a fault.
  final noise = _noise.hasMatch(body);
  final failed = !noise && _failure.hasMatch(body);

  switch (tag) {
    case 'NOSTR':
      final up = _connected.firstMatch(body);
      if (up != null) {
        return FriendlyLogLine(
          kind: LogKind.internet,
          text: t.logServerConnected(up.group(1)!),
        );
      }
      final down = _down.firstMatch(body);
      if (down != null) {
        return FriendlyLogLine(
          kind: LogKind.internet,
          text: t.logServerLost(down.group(1)!),
        );
      }
      if (body.startsWith('internet fallback on')) {
        return FriendlyLogLine(kind: LogKind.internet, text: t.logInternetOn);
      }
      return failed ? _problem(body) : null;
    case 'BOOT':
      if (body.startsWith('cubechat ')) {
        return FriendlyLogLine(kind: LogKind.startup, text: t.logAppStarted);
      }
      return failed ? _problem(body) : null;
    case 'CRASH':
      return _problem(body);
  }

  final kind = _kinds[tag];
  if (kind == null) {
    // Frame timings, receipts, presence, crypto steps, untagged prints: the
    // developer's, unless something in them failed.
    return failed ? _problem(body) : null;
  }
  if (failed) return _problem(body);
  return FriendlyLogLine(kind: kind, text: shortenLogText(body));
}

FriendlyLogLine _problem(String body) =>
    FriendlyLogLine(kind: LogKind.problem, text: shortenLogText(body));

/// A log sentence with the parts nobody reads taken out: public keys and ids
/// cut to their first six characters, a relay's publish receipt dropped, and
/// the whole thing held to one readable length.
@visibleForTesting
String shortenLogText(String body) {
  var text = body
      .replaceAll(_receipt, '')
      .replaceAllMapped(_hex, (m) => '${m.group(0)!.substring(0, 6)}…')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.length > 140) text = '${text.substring(0, 139)}…';
  return text;
}

final RegExp _tagged = RegExp(r'^\[([A-Z0-9_-]+)\]\s?(.*)$', dotAll: true);
final RegExp _connected = RegExp(r'^connected wss?://([^\s/]+)');
final RegExp _down = RegExp(r'^wss?://([^\s/]+)(?:/\S*)? down\b');
final RegExp _hex = RegExp(r'\b[0-9a-f]{16,}\b');
final RegExp _receipt = RegExp(r'\s*—\s*PublishReceipt\(.*\)$');
final RegExp _failure = RegExp(
  r'\b(fail(ed|s|ure)?|error|exception|crash(ed)?|could ?not|cannot|denied)\b',
  caseSensitive: false,
);
final RegExp _noise = RegExp(
  r'rate limited|auth-required|nothing to ack|renewing inbox',
  caseSensitive: false,
);

const Map<String, LogKind> _kinds = {
  'BLE-CENTRAL': LogKind.bluetooth,
  'BLE-SCAN': LogKind.bluetooth,
  'PERIPH-CTL': LogKind.bluetooth,
  'PERIPH-NATIVE': LogKind.bluetooth,
  'CHAT': LogKind.chats,
  'CHAN': LogKind.chats,
  'EDIT': LogKind.chats,
  'PIN': LogKind.chats,
  'REACT': LogKind.chats,
  'VIEWONCE': LogKind.chats,
  'STICKER': LogKind.chats,
  'SHARE': LogKind.chats,
  'LINK': LogKind.chats,
  'FILE': LogKind.media,
  'IMG': LogKind.media,
  'PHOTO': LogKind.media,
  'MEDIA': LogKind.media,
  'GALLERY': LogKind.media,
  'CIRCLE': LogKind.media,
  'VOICE': LogKind.media,
  'AUDIO': LogKind.media,
  'ATTACH': LogKind.media,
  'AVATAR': LogKind.media,
  'CALL': LogKind.calls,
  'LOCATION': LogKind.location,
  'MAP': LogKind.location,
  'BACKUP': LogKind.backup,
  'PUSH': LogKind.internet,
};
