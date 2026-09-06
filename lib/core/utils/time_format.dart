import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';

String formatChatListTime(BuildContext context, DateTime time) {
  final now = DateTime.now();
  final t = AppLocalizations.of(context);
  final locale = Localizations.localeOf(context).toLanguageTag();

  if (_sameDay(now, time)) {
    return DateFormat.Hm(locale).format(time);
  }
  if (_sameDay(now.subtract(const Duration(days: 1)), time)) {
    return t.chatYesterday;
  }
  if (now.difference(time).inDays < 7) {
    return DateFormat.E(locale).format(time);
  }
  return DateFormat.yMd(locale).format(time);
}

/// When somebody was last in the app, said the way a person would say it.
///
/// Three registers, because the useful answer changes with the age of it:
///
///   * **Under a minute** — "just now". Nobody says "one minute ago" about
///     somebody who is still putting their phone down, and a counter that
///     starts at zero minutes reads as broken.
///   * **Under an hour** — "N minutes ago". This is the range where the number
///     is what you want: whether they left four minutes ago or forty changes
///     whether you wait.
///   * **Past an hour** — hours, while they are still a number somebody holds.
///   * **Yesterday** — the day and the hour, because "вчора о 00:30" is what a
///     person says and "37 hours ago" is arithmetic they have to do.
///   * **This week** — the day spelled out. Not the abbreviation
///     [formatChatListTime] uses: that one is sized for a chat row, where "чт"
///     beside a name is all there is room for, and in a sentence about a person
///     it reads as a stray letter.
///   * **Past that** — weeks, then months. What somebody says out loud about a
///     gap that size. A date is what they look up when they need one, and this
///     line is not where anybody looks anything up.
///
/// Every step is a separate phrase in the ARB rather than a formatter's output
/// with a preposition pasted in front, because "у середу" is not "у середа" and
/// a language that inflects cannot be served that way.
String formatLastSeen(BuildContext context, DateTime time) {
  final t = AppLocalizations.of(context);
  final now = DateTime.now();
  final elapsed = now.difference(time);
  // A clock that has gone backwards — theirs or ours — is not a reason to show
  // a negative count. "Just now" is the honest reading of a stamp that has not
  // happened yet by a few seconds.
  if (elapsed.inMinutes < 1) return t.presenceJustNow;
  if (elapsed.inMinutes < 60) return t.presenceMinutesAgo(elapsed.inMinutes);
  // Hours, while they are still a small number somebody can hold.
  if (elapsed.inHours < 24) return t.presenceHoursAgo(elapsed.inHours);

  final locale = Localizations.localeOf(context).toLanguageTag();
  // Yesterday, with the hour — "вчора о 00:30". It still reaches here past the
  // 24-hour rule above: seen at half past midnight and read late the following
  // night is forty-six hours by the clock and yesterday by the calendar, and
  // the calendar is what a person means.
  if (_sameDay(now.subtract(const Duration(days: 1)), time)) {
    return t.presenceYesterdayAt(DateFormat.Hm(locale).format(time));
  }
  // The day itself, spelled out. `formatChatListTime` abbreviates — it is
  // sized for a chat row, where "чт" beside a name is all there is room for —
  // and in a sentence about a person that reads as a stray letter rather than
  // as Thursday. Selected on the weekday number in the ARB, because "у середу"
  // is not "у середа" and a locale that inflects cannot be served by pasting a
  // preposition in front of a formatter's output.
  if (elapsed.inDays < 7) return t.presenceOnWeekday(time.weekday.toString());
  // Weeks, then months. Both are what somebody says out loud about a gap that
  // size; a date is what they look up when they need one, and this line is not
  // where anybody looks anything up.
  if (elapsed.inDays < 28) return t.presenceWeeksAgo(elapsed.inDays ~/ 7);
  if (elapsed.inDays < 365) {
    return t.presenceMonthsAgo((elapsed.inDays / 30).floor().clamp(1, 12));
  }
  return t.presenceLongAgo;
}

String formatBubbleTime(BuildContext context, DateTime time) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  return DateFormat.Hm(locale).format(time);
}

/// Timestamp for the long-press message details: bare time for today, date +
/// time for anything older. Details are read to answer "when exactly", so
/// unlike the bubble's clock this one never hides the day.
String formatMessageDetailsTime(BuildContext context, DateTime time) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final hm = DateFormat.Hm(locale).format(time);
  if (_sameDay(DateTime.now(), time)) return hm;
  return '${DateFormat.MMMd(locale).format(time)}, $hm';
}

/// The label on a day separator in a conversation.
///
/// Today and yesterday get their names, because that is how anybody refers to
/// them. Everything else gets the date — without the year while it is this
/// year, since a conversation is almost entirely made of the current one and
/// repeating it on every separator is noise. An older message keeps its year,
/// which is exactly when the year is the interesting part.
String formatDayHeader(BuildContext context, DateTime day) {
  final t = AppLocalizations.of(context);
  final now = DateTime.now();
  final locale = Localizations.localeOf(context).toLanguageTag();
  if (_sameDay(now, day)) return t.chatToday;
  if (_sameDay(now.subtract(const Duration(days: 1)), day)) {
    return t.chatYesterday;
  }
  if (day.year == now.year) return DateFormat.MMMMd(locale).format(day);
  return DateFormat.yMMMMd(locale).format(day);
}

/// The heading over one month of the calendar.
///
/// The year is dropped while it is this year, for the same reason the day
/// separator drops it: a conversation is mostly made of the current year, and
/// repeating it above every month is noise that the one older month actually
/// needs.
String formatMonthHeader(BuildContext context, DateTime month) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  if (month.year == DateTime.now().year) {
    return DateFormat.MMMM(locale).format(month);
  }
  return DateFormat.yMMMM(locale).format(month);
}

/// Whether [message] is the first one of its calendar day, given the message
/// before it in the conversation.
///
/// Null [previous] means it is the first message there is, which always opens a
/// day. Compared by local calendar date rather than by elapsed hours: two
/// messages forty minutes apart are on different days when one is at ten to
/// midnight, and that is precisely the boundary a reader is looking for.
bool startsNewDay(DateTime message, DateTime? previous) =>
    previous == null || !_sameDay(previous, message);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
