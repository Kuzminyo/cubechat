part of '../profile_screen.dart';

/// Privacy & security: what other people are told about you, who may write
/// from the internet, and what protects the phone itself.
class PrivacySectionScreen extends ConsumerWidget {
  const PrivacySectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    return SettingsSectionScaffold(
      title: t.sectionPrivacy,
      children: [
        SettingsSubheader(t.subWhoSeesMe),
        SettingsGroup(
          children: [
            _inset(const _LastSeenTile()),
            _inset(const _ReadReceiptsTile()),
            _inset(const _ForwardLinkTile()),
            _inset(const _DiscoverableCard(framed: false), vertical: 0),
            _inset(const _MapLocationTile()),
          ],
        ),
        SettingsSubheader(t.strangerReachTitle),
        SettingsGroup(
          children: [
            _inset(
              const StrangerReachSelector(showTitle: false),
              vertical: 14,
            ),
          ],
        ),
        SettingsSubheader(t.subProtection),
        SettingsGroup(
          children: [
            _inset(const _AppLockTile()),
            _inset(const _FilterTile()),
            _inset(const _DeadMansRow()),
            _inset(const _FingerprintTile()),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          child: Text(
            t.profilePrivacyExplainer,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
