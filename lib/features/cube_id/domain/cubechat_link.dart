import '../../../core/transport/contact_card.dart';
import 'cube_name.dart';

/// A link on cubechat.tech that the app opens itself: a shared @name
/// (`/u.html#dima`) or a whole contact card (`/c1#cubechat:c1:…`).
///
/// The payload is in the fragment in both, which a browser never sends to a
/// server — so the site learns nothing about who is being shared, and the app
/// reads it straight out of the link it was handed.
sealed class CubechatLink {
  const CubechatLink();
}

class NameLink extends CubechatLink {
  const NameLink(this.name);
  final String name;
}

class CardLink extends CubechatLink {
  const CardLink(this.raw);

  /// Text to hand `addContactFromCard` — it finds the card token inside.
  final String raw;
}

const String _host = 'cubechat.tech';

CubechatLink? parseCubechatLink(Uri uri) {
  if (uri.scheme != 'https' || uri.host != _host) return null;
  final fragment = Uri.decodeComponent(uri.fragment);
  if (uri.path == '/u.html') {
    final name = normalizeCubeName(fragment);
    return cubeNameProblem(name) == CubeNameProblem.invalid
        ? null
        : NameLink(name);
  }
  if (uri.path == '/c1' || uri.path == '/c1/') {
    return ContactCard.looksLikeCard(fragment) ? CardLink(fragment) : null;
  }
  return null;
}
