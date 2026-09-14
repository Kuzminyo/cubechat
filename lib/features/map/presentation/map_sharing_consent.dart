import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../profile/data/privacy_settings_controller.dart';

/// Ask before this phone's location goes on anybody's map, and switch sharing
/// on only for a yes.
///
/// Every road into sharing comes through here — the profile switch, the Show
/// me pill on the map, sending a map invitation, accepting one. Each of those
/// used to turn sharing on by itself, on the reasoning that the tap was the
/// consent. App Store review rejected that under guideline 5.1.2(i): a person
/// must be asked for permission to display their location on a map, in words,
/// with the option to decline.
///
/// Answers true when sharing is on afterwards — already on, or just allowed.
/// Hiding needs no question and does not come here.
Future<bool> confirmMapSharing(BuildContext context, WidgetRef ref) async {
  if (ref.read(privacySettingsProvider).shareMapLocation) return true;
  final t = AppLocalizations.of(context);
  final allowed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('map-share-consent'),
      title: Text(t.mapShareConsentTitle),
      content: Text(t.mapShareConsentBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.mapShareConsentDecline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.mapShareConsentAllow),
        ),
      ],
    ),
  );
  if (allowed != true) return false;
  await ref.read(privacySettingsProvider.notifier).setShareMapLocation(true);
  return true;
}
