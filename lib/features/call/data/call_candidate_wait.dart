import 'dart:async';

/// Publish a self-contained SDP once a relay is usable. Waiting for every
/// interface also waits for dead VPN/mobile routes on otherwise connected phones.
Future<void> waitForCallCandidates({
  required Future<void> gathered,
  required Future<void> relayReady,
  Duration settle = const Duration(milliseconds: 400),
  Duration timeout = const Duration(seconds: 12),
}) =>
    Future.any([
      gathered,
      relayReady.then((_) => Future<void>.delayed(settle)),
    ]).timeout(timeout);
