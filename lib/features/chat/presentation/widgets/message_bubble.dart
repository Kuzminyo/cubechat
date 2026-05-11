import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/message.dart';

class MessageBubble extends StatefulWidget {
  const MessageBubble({super.key, required this.message});

  final Message message;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();

  late final Animation<double> _scale =
      CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.15),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final mine = message.isMine;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(mine ? 18 : 6),
      bottomRight: Radius.circular(mine ? 6 : 18),
    );

    final bubble = ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: mine
              ? BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.brandPrimary.withValues(alpha: 0.85),
                      AppColors.brandSecondary.withValues(alpha: 0.85),
                    ],
                  ),
                  borderRadius: radius,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                )
              : BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: radius,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message.text,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 14.5,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 4),
              _BubbleMeta(message: message),
            ],
          ),
        ),
      ),
    );

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(_scale),
          alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: Row(
              mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
                  child: bubble,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleMeta extends StatelessWidget {
  const _BubbleMeta({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final time = formatBubbleTime(context, message.sentAt);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          time,
          style: TextStyle(
            fontSize: 10.5,
            color: Colors.white.withValues(alpha: message.isMine ? 0.8 : 0.5),
          ),
        ),
        if (message.isMine) ...[
          const SizedBox(width: 4),
          Icon(
            switch (message.status) {
              MessageStatus.sending => Icons.schedule,
              MessageStatus.delivered => Icons.done,
              MessageStatus.read => Icons.done_all,
              MessageStatus.failed => Icons.error_outline,
            },
            size: 12,
            color: switch (message.status) {
              MessageStatus.failed => AppColors.danger,
              _ => Colors.white.withValues(alpha: 0.85),
            },
            semanticLabel: switch (message.status) {
              MessageStatus.sending => t.chatSending,
              MessageStatus.delivered => t.chatDelivered,
              MessageStatus.read => t.chatRead,
              MessageStatus.failed => '!',
            },
          ),
        ],
      ],
    );
  }
}
