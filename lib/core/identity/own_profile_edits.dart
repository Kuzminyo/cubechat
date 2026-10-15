import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Counts changes the person made **by hand on this device** to their
/// nickname or avatar. Each one is sent to the account's other devices
/// (`OwnProfileSync.edited`).
///
/// A change that arrived from another device, a restore, a wipe or a read
/// from disk does not count. Listening to the nickname or the avatar itself
/// cannot tell those apart: the avatar loads from disk as a change from null,
/// so every launch would have sent the picture, and every profile applied
/// from another device would have been sent straight back.
final ownProfileEditsProvider = StateProvider<int>((_) => 0);
