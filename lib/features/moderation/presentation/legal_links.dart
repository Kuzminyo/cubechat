import 'package:flutter/widgets.dart';

/// The site copy has not yet been updated for moderation. Link the full,
/// versioned documents in the public repository so the consent screen never
/// opens a 404 or an outdated policy.
Uri termsDocumentUrl(BuildContext context) => Uri.parse(
      Localizations.localeOf(context).languageCode == 'uk'
          ? 'https://github.com/Kuzminyo/cubechat/blob/main/docs/legal/terms.uk.md'
          : 'https://github.com/Kuzminyo/cubechat/blob/main/docs/legal/terms.en.md',
    );

Uri privacyDocumentUrl(BuildContext context) => Uri.parse(
      Localizations.localeOf(context).languageCode == 'uk'
          ? 'https://github.com/Kuzminyo/cubechat/blob/main/docs/legal/privacy-policy.uk.md'
          : 'https://github.com/Kuzminyo/cubechat/blob/main/docs/legal/privacy-policy.en.md',
    );
