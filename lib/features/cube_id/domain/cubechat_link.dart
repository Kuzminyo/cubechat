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

/// Also read: the forms the cubechat.tech page uses to hand a link to the app
/// when the system did not — `?n=`/`?c=` on the https path (Android's
/// `intent://` carries a query, since the fragment is taken by `#Intent`),
/// and the `cubechat://u?n=…` / `cubechat://c1?c=…` scheme (iOS). And a bare
/// `cubechat:c1:…` card, which old QR codes and pasted cards are.
CubechatLink? parseCubechatLink(Uri uri) {
  if (uri.scheme == 'cubechat') {
    if (uri.host == 'u') return _name(uri.queryParameters['n'] ?? '');
    if (uri.host == 'c1') return _card(uri.queryParameters['c'] ?? '');
    // The share extension opening the app (ios/ShareExtension): arriving is
    // the whole message, and the share itself comes through ShareInbox.
    if (uri.host == 'share') return null;
    return _card(uri.toString());
  }
  if (uri.scheme != 'https' || uri.host != _host) return null;
  final fragment = Uri.decodeComponent(uri.fragment);
  if (uri.path == '/u.html') {
    return _name(uri.queryParameters['n'] ?? fragment);
  }
  if (uri.path == '/c1' || uri.path == '/c1/') {
    return _card(uri.queryParameters['c'] ?? fragment);
  }
  return null;
}

CubechatLink? _name(String raw) {
  final name = normalizeCubeName(raw);
  return cubeNameProblem(name) == CubeNameProblem.invalid
      ? null
      : NameLink(name);
}

CubechatLink? _card(String raw) =>
    ContactCard.looksLikeCard(raw) ? CardLink(raw) : null;
