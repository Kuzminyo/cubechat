part of '../profile_screen.dart';

/// Data & storage: what the app keeps, and the ways to carry it elsewhere.
class DataSectionScreen extends ConsumerWidget {
  const DataSectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return SettingsSectionScaffold(
      title: t.sectionData,
      children: [
        SettingsGroup(
          children: [
            _inset(const _StorageRow(), vertical: 0),
            _inset(const _FileTransfersCard(framed: false), vertical: 0),
            _inset(const _BackupCard(framed: false), vertical: 0),
            _inset(const PhoneTransferCard(framed: false), vertical: 0),
            // A phone hands its account to a computer, never the other way.
            if (PlatformInfo.isMobile)
              _inset(const ConnectComputerRow(), vertical: 0)
            else if (!PlatformInfo.isWeb)
              _inset(const ImportFromPhoneRow(), vertical: 0),
            // An update installed from here keeps lock-screen calls on. See
            // [SelfUpdate].
            if (PlatformInfo.isAndroid) _inset(const _InstallUpdateRow()),
          ],
        ),
      ],
    );
  }
}
