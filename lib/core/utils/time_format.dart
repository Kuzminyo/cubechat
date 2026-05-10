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

String formatDayHeader(BuildContext context, DateTime day) {
  final t = AppLocalizations.of(context);
  final now = DateTime.now();
  final locale = Localizations.localeOf(context).toLanguageTag();
  if (_sameDay(now, day)) return t.chatToday;
  if (_sameDay(now.subtract(const Duration(days: 1)), day)) return t.chatYesterday;
  return DateFormat.yMMMMd(locale).format(day);
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
