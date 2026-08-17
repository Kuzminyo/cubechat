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
