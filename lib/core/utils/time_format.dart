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
///   * **Past an hour** — the clock, and then the day. By then the elapsed time
///     has stopped being the useful form — "was 214 minutes ago" is arithmetic
///     somebody has to do — and the wall clock is what a person remembers
///     against. Handed to [formatChatListTime], which already knows how to
///     shorten yesterday and last week.
///
/// Asked for in those three pieces, in those words.
String formatLastSeen(BuildContext context, DateTime time) {
  final t = AppLocalizations.of(context);
  final elapsed = DateTime.now().difference(time);
  // A clock that has gone backwards — theirs or ours — is not a reason to show
  // a negative count. "Just now" is the honest reading of a stamp that has not
  // happened yet by a few seconds.
  if (elapsed.inMinutes < 1) return t.presenceJustNow;
  if (elapsed.inMinutes < 60) return t.presenceMinutesAgo(elapsed.inMinutes);
  // Hours, while they are still a small number somebody can hold. Past a day
  // the count stops being the useful form — "was 37 hours ago" is arithmetic
  // again — and the clock with its day takes over.
  if (elapsed.inHours < 24) return t.presenceHoursAgo(elapsed.inHours);
  return formatChatListTime(context, time);
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
