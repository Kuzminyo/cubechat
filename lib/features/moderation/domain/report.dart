/// Why somebody is being reported. Mirrors the push server's
/// `REPORT_REASONS` in `push/src/index.js` exactly — a value not in that set
/// is rejected with 400 `payload`, so this enum's names *are* the wire
/// values (`.name`), not a separate mapping to keep in sync by hand.
enum ReportReason { spam, abuse, violence, sexual, other }

/// Where the reported thing was seen. Mirrors `REPORT_CONTEXTS` on the
/// server the same way [ReportReason] does.
enum ReportContext { direct, channel, airdrop, general }

/// What kind of message is attached to the report, if any. Mirrors
/// `REPORT_MESSAGE_KINDS` on the server the same way [ReportReason] does.
enum ReportedKind { text, photo, video, voice, file, sticker, other }

/// A report, ready to become the `content` of a signed Nostr event.
///
/// [toJson] is the one place the field names and caps have to match
/// `parseReportPayload` in `push/src/index.js` byte for byte — see
/// `test/report_client_test.dart`'s payload-shape test, which checks this
/// output against that function's rules directly rather than trusting a
/// paraphrase here.
class ModerationReport {
  ModerationReport({
    required this.reason,
    this.note,
    this.target,
    this.targetNpub,
    required this.context,
    this.channelId,
    this.messageText,
    this.messageKind,
    this.messageSentAt,
  });

  final ReportReason reason;

  /// Free text from the "інше" field. Capped at 500 chars on the way out —
  /// never thrown, since a report that a person spent a minute writing must
  /// not be lost to a length check at the last second.
  final String? note;

  /// The reported person's identity key (64 hex) — required by the server
  /// when [context] is [ReportContext.direct], optional (but validated the
  /// same way when present) everywhere else.
  final String? target;

  /// The reported person's Nostr key (64 hex), when the caller knows it.
  /// Always included when known: it's the only way the server can later
  /// refuse push/TURN to a banned npub it was never told about. A later task
  /// (A3) is what actually fills this in from the peer roster.
  final String? targetNpub;

  final ReportContext context;

  /// Which channel this happened in, for a [ReportContext.channel] report.
  final String? channelId;

  /// The reported message's text, if the report is about one message.
  /// Capped at 4000 chars, truncated rather than thrown, same as [note].
  final String? messageText;
  final ReportedKind? messageKind;

  /// Unix milliseconds the reported message was sent — spec §3 says `ms`.
  /// The server accepts any non-negative safe integer, so seconds would have
  /// passed validation silently and read as January 1970 to the moderator.
  final int? messageSentAt;

  static const int noteMaxChars = 500;
  static const int messageTextMaxChars = 4000;

  static String _truncate(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  /// The wire payload — exactly the shape `parseReportPayload` on the push
  /// server accepts, key for key. Optional fields are omitted rather than
  /// sent as `null`, because the server's own encoder does the same (see its
  /// `...(x !== undefined ? {x} : {})` spread) and a `null` that survives a
  /// round trip through [fromJson] must not read back as "the field was
  /// present but empty".
  Map<String, Object?> toJson() {
    final hasMessage =
        messageText != null || messageKind != null || messageSentAt != null;
    return {
      'reason': reason.name,
      'context': context.name,
      if (note != null) 'note': _truncate(note!, noteMaxChars),
      if (target != null) 'target': target,
      if (targetNpub != null) 'targetNpub': targetNpub,
      if (channelId != null) 'channelId': channelId,
      if (hasMessage)
        'message': {
          if (messageText != null)
            'text': _truncate(messageText!, messageTextMaxChars),
          if (messageKind != null) 'kind': messageKind!.name,
          if (messageSentAt != null) 'sentAt': messageSentAt,
        },
    };
  }

  /// The inverse of [toJson], for reading a queued entry back off disk.
  /// Returns `null` rather than throwing on anything malformed — a corrupt
  /// queue entry (an old shape, a hand-edited box) must not crash `flush()`,
  /// it should just be dropped, same as a payload the server itself refuses.
  static ModerationReport? fromJson(Map<dynamic, dynamic> json) {
    try {
      final reason = ReportReason.values.asNameMap()[json['reason']];
      final context = ReportContext.values.asNameMap()[json['context']];
      if (reason == null || context == null) return null;

      String? messageText;
      ReportedKind? messageKind;
      int? messageSentAt;
      final message = json['message'];
      if (message is Map) {
        final text = message['text'];
        if (text is String) messageText = text;
        final kind = message['kind'];
        if (kind is String) messageKind = ReportedKind.values.asNameMap()[kind];
        final sentAt = message['sentAt'];
        if (sentAt is int) messageSentAt = sentAt;
      }

      final note = json['note'];
      final target = json['target'];
      final targetNpub = json['targetNpub'];
      final channelId = json['channelId'];

      return ModerationReport(
        reason: reason,
        note: note is String ? note : null,
        target: target is String ? target : null,
        targetNpub: targetNpub is String ? targetNpub : null,
        context: context,
        channelId: channelId is String ? channelId : null,
        messageText: messageText,
        messageKind: messageKind,
        messageSentAt: messageSentAt,
      );
    } catch (_) {
      return null;
    }
  }
}
