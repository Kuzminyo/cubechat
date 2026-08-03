import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';

Future<void> showChannelPollComposer(
  BuildContext context,
  WidgetRef ref,
  String channelName,
) async {
  final t = AppLocalizations.of(context);
  final question = TextEditingController();
  final options = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];

  final create = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        title: Text(
          t.channelCreatePoll,
          style: TextStyle(color: AppColors.textOnGlass),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: question,
                autofocus: true,
                maxLength: 240,
                style: TextStyle(color: AppColors.textOnGlass),
                decoration: InputDecoration(labelText: t.channelPollQuestion),
              ),
              for (var index = 0; index < options.length; index++)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: options[index],
                    maxLength: 100,
                    style: TextStyle(color: AppColors.textOnGlass),
                    decoration: InputDecoration(
                      labelText: t.channelPollOption(index + 1),
                      suffixIcon: options.length > 2
                          ? IconButton(
                              onPressed: () => setState(() {
                                options.removeAt(index).dispose();
                              }),
                              icon: const Icon(Icons.close_rounded),
                            )
                          : null,
                    ),
                  ),
                ),
              if (options.length < 10)
                TextButton.icon(
                  onPressed: () => setState(
                    () => options.add(TextEditingController()),
                  ),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t.channelPollAddOption),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () {
              final valid = question.text.trim().isNotEmpty &&
                  options.where((item) => item.text.trim().isNotEmpty).length >=
                      2;
              if (valid) Navigator.pop(dialogContext, true);
            },
            child: Text(t.channelPollCreate),
          ),
        ],
      ),
    ),
  );

  if (create == true && context.mounted) {
    try {
      await ref.read(messagingServiceProvider).sendChannelPoll(
            channelName,
            question.text,
            options
                .map((controller) => controller.text)
                .where((value) => value.trim().isNotEmpty)
                .toList(growable: false),
          );
    } catch (error) {
      if (context.mounted) {
        showGlassToast(
          context,
          error.toString(),
          icon: Icons.error_outline_rounded,
          tone: ToastTone.danger,
        );
      }
    }
  }
  question.dispose();
  for (final controller in options) {
    controller.dispose();
  }
}
