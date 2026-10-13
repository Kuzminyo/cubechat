/// Which road a frame meant for the person standing next to us takes.
enum DirectWritePath {
  /// Write to the link we opened to them, whose outbound characteristic is
  /// there.
  client,

  /// Notify from our peripheral: they are connected to us as a central.
  peripheral,

  /// Our link to them is up but still discovering services, and it is the
  /// only road — wait for it rather than fail.
  waitForClient,

  /// No link to them.
  none,
}

/// Chooses the road for an AirDrop frame — a bump, an offer, an answer.
///
/// **Ready, not connected.** A link is "connected" a moment after the radio
/// is, and its outbound characteristic only exists once its services have been
/// found. A write in between throws "outbound characteristic not ready"; in a
/// log of a bump on 2026-10-13 that was two and a half seconds, and the bump
/// went out as "could not reach" while the iPhone's own connection to this
/// phone's peripheral was already carrying a session. Mesh fan-out learnt this
/// long ago (`_fanoutAllLinks` skips a client that is not ready); the direct
/// write did not.
DirectWritePath directWritePath({
  required bool hasClient,
  required bool clientReady,
  required bool clientConnected,
  required bool peerIsCentral,
}) {
  if (hasClient && clientReady) return DirectWritePath.client;
  if (peerIsCentral) return DirectWritePath.peripheral;
  if (hasClient && clientConnected) return DirectWritePath.waitForClient;
  return DirectWritePath.none;
}
