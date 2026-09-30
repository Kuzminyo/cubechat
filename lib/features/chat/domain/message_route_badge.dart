import '../models/message.dart';

/// The three roads a message can have taken, as the mark beside its time.
enum RouteBadgeKind { bluetooth, mesh, internet }

/// Which way [m] travelled, or null when there is nothing true to say.
///
/// Every message has recorded its road for a long while — [Message.route],
/// set on send when a link took it and on arrival from the link it came in
/// on — but only the chat header ever showed a road, and that one is the
/// road *now*. This is the road *this* message took, which is the one thing
/// no other messenger can show: the same chat can be Bluetooth in the kitchen
/// and the internet an hour later.
///
/// Nothing for a message that has not arrived yet (a queued one already shows
/// its cloud, and a road for one still sending would be a guess), and nothing
/// for the old messages that predate the field. A mesh hop count under two
/// is left off: one hop is Bluetooth by another name.
({RouteBadgeKind kind, int? hops})? routeBadgeFor(Message m) {
  if (m.isMine &&
      (m.status == MessageStatus.sending ||
          m.status == MessageStatus.failed)) {
    return null;
  }
  final hops = m.routeHops;
  return switch (m.route) {
    MessageRoute.bluetooth => (kind: RouteBadgeKind.bluetooth, hops: null),
    MessageRoute.mesh => (
        kind: RouteBadgeKind.mesh,
        hops: hops != null && hops >= 2 ? hops : null,
      ),
    MessageRoute.internet => (kind: RouteBadgeKind.internet, hops: null),
    MessageRoute.queued || null => null,
  };
}
