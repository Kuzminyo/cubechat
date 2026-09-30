part of '../profile_screen.dart';

/// Connection: the Bluetooth mesh, running in the background, and the
/// internet fallback through relays.
class ConnectionSectionScreen extends ConsumerWidget {
  const ConnectionSectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return SettingsSectionScaffold(
      title: t.sectionConnection,
      children: [
        SettingsGroup(
          children: [
            _inset(const _MeshSwitchCard(framed: false), vertical: 0),
            _inset(const _TransportRow(), vertical: 0),
            _inset(const _BackgroundModeCard(framed: false), vertical: 0),
            _inset(const _RelayFallbackCard(framed: false), vertical: 0),
          ],
        ),
      ],
    );
  }
}
