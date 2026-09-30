part of '../profile_screen.dart';

/// Notifications & calls: what may wake the phone, and who may ring it.
class NotificationsSectionScreen extends ConsumerWidget {
  const NotificationsSectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return SettingsSectionScaffold(
      title: t.sectionNotifications,
      children: [
        SettingsSubheader(t.subNotifications),
        SettingsGroup(
          children: [
            if (PlatformInfo.isMobile) _inset(const _PushWakeRow()),
            _inset(const _QuietHoursRow()),
          ],
        ),
        SettingsSubheader(t.subCalls),
        SettingsGroup(
          children: [
            _inset(const _AcceptCallsTile()),
            _inset(const _CallDirectTile()),
            if (PlatformInfo.isAndroid) _inset(const _CallFullScreenTile()),
          ],
        ),
      ],
    );
  }
}
