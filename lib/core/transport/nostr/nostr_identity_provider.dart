import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/identity_service.dart';
import 'nostr_signer.dart';

/// This device's Nostr address (x-only secp256k1 pubkey, hex) — the address a
/// peer publishes to when the mesh can't reach us. Derived deterministically
/// from the identity seed, so it's stable across restarts and dies with an
/// emergency wipe (which replaces the seed).
final myNpubProvider = FutureProvider<String>((ref) async {
  final identity = await ref.watch(identityProvider.future);
  final signer = await Secp256k1NostrSigner.deriveFromSeed(
    Uint8List.fromList(identity.signPrivateKey),
  );
  return signer.npubHex;
});
