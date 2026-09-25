import 'package:flutter/widgets.dart';

/// The pages now live on our own domain (landing_cubechat's public/terms.html
/// and public/privacy.html), not on GitHub — App Review needs to see them at
/// cubechat.tech. Both pages are bilingual with their own uk/en toggle and
/// pick a starting language from the browser, so one URL per document is
/// enough; `context`'s locale no longer changes the target.
Uri termsDocumentUrl(BuildContext context) =>
    Uri.parse('https://cubechat.tech/terms.html');

Uri privacyDocumentUrl(BuildContext context) =>
    Uri.parse('https://cubechat.tech/privacy.html');
