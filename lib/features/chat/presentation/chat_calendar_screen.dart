import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/routing/page_transitions.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/aurora_background.dart';
import '../../../l10n/app_localizations.dart';
import '../models/message.dart';

/// A month of a conversation, as the days it actually has.
@immutable
class ConversationDay {
  const ConversationDay({
    required this.day,
    required this.count,
    this.firstPhoto,
  });

  /// Midnight of the day, so two of them compare as days rather than moments.
  final DateTime day;

  /// How much was said. Drawn small under the date, because "one message" and
  /// "two hundred" are different kinds of day and the square cannot say so on
  /// its own.
  final int count;

  /// The first picture sent that day, if there was one and the file is still
  /// on this device.
  final String? firstPhoto;
}

/// The days of [messages], oldest first, one entry per day that has anything.
///
/// Deliberately not a full month grid with holes: a conversation is not a
/// calendar, and a wall of empty squares would say mostly nothing. What is
/// worth seeing is which days exist and which of them have a photograph.
List<ConversationDay> conversationDays(List<Message> messages) {
  final byDay = <DateTime, List<Message>>{};
  for (final message in messages) {
    final at = message.sentAt;
    final day = DateTime(at.year, at.month, at.day);
    (byDay[day] ??= <Message>[]).add(message);
  }

  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      ConversationDay(
        day: day,
        count: byDay[day]!.length,
        firstPhoto: _firstPhotoOf(byDay[day]!),
      ),
  ];
}

/// The first photo of the day that is still on disk.
///
/// Checked rather than assumed: a picture whose file has been cleaned up would
/// otherwise leave a square that renders an error box, which looks like the
/// calendar is broken rather than like the photo is gone.
String? _firstPhotoOf(List<Message> ofDay) {
  for (final message in ofDay) {
    final path = message.imagePath;
    if (path == null || path.isEmpty) continue;
    if (!File(path).existsSync()) continue;
    return path;
  }
  return null;
}

/// Open the calendar and answer with the day the user picked, or null.
Future<DateTime?> showChatCalendar(
  BuildContext context, {
  required List<Message> messages,
  DateTime? current,
}) {
  return Navigator.of(context).push<DateTime>(
    mediaRoute<DateTime>(
      (_) => ChatCalendarScreen(messages: messages, current: current),
    ),
  );
}

class ChatCalendarScreen extends StatelessWidget {
  const ChatCalendarScreen({
    super.key,
    required this.messages,
    this.current,
  });

  final List<Message> messages;

  /// The day the conversation is standing on, marked so the reader can see
  /// where they came from.
  final DateTime? current;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final days = conversationDays(messages);

    // Grouped by month, newest month first: a scrollback is read backwards,
    // and the day somebody is looking for is far more often near the end than
    // near the beginning.
    final months = <DateTime, List<ConversationDay>>{};
    for (final day in days.reversed) {
      final month = DateTime(day.day.year, day.day.month);
      (months[month] ??= <ConversationDay>[]).add(day);
    }

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: BackButton(color: AppColors.textOnGlass),
          title: Text(
            t.chatCalendarTitle,
            style: AppTypography.heading(
              size: AppMenu.title,
              color: AppColors.textOnGlass,
            ),
          ),
        ),
        body: days.isEmpty
            ? Center(
                child: Text(
                  t.chatCalendarEmpty,
                  style: TextStyle(color: AppColors.textOnGlassDim),
                ),
              )
            : SafeArea(
                top: false,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    for (final month in months.keys)
                      _MonthBlock(
                        month: month,
                        days: months[month]!,
                        current: current,
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _MonthBlock extends StatelessWidget {
  const _MonthBlock({
    required this.month,
    required this.days,
    required this.current,
  });

  final DateTime month;
  final List<ConversationDay> days;
  final DateTime? current;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 10),
          child: Text(
            formatMonthHeader(context, month),
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            // Oldest first inside a month, so the days read left to right the
            // way a month does, even though the months themselves descend.
            for (final day in days.reversed)
              _DaySquare(
                day: day,
                isCurrent: current != null &&
                    !startsNewDay(day.day, current),
              ),
          ],
        ),
      ],
    );
  }
}

class _DaySquare extends StatelessWidget {
  const _DaySquare({required this.day, required this.isCurrent});

  final ConversationDay day;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final photo = day.firstPhoto;
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(day.day),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (photo != null)
              Image.file(
                File(photo),
                fit: BoxFit.cover,
                // Decoded to the square it is drawn in, never to the size the
                // camera took it at — an uncapped decode of a dozen of these
                // is the cost this repo has measured and cut before.
                cacheWidth: 220,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              )
            else
              ColoredBox(color: AppColors.glass(0.07)),
            // A photo is a bright thing to write a date on, so the date gets
            // its own ground rather than trusting the picture to be dark.
            if (photo != null)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isCurrent
                      ? AppColors.brandPrimary
                      : AppColors.glass(0.14),
                  width: isCurrent ? 2 : 1,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${day.day.day}',
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      shadows: photo != null
                          ? const [Shadow(blurRadius: 4, color: Colors.black)]
                          : null,
                    ),
                  ),
                  Text(
                    '${day.count}',
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 10.5,
                      shadows: photo != null
                          ? const [Shadow(blurRadius: 4, color: Colors.black)]
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
