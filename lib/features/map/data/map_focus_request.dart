import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A request to point the map at somebody.
///
/// The list of people on the map is a modal sheet *over* the map, so it has no
/// way to reach that screen's camera directly — by the time the tap is handled
/// the sheet is on its way out and its context is gone. It leaves a request
/// here instead and pops; the map is listening and moves.
///
/// Deliberately without value equality: two taps on the same person are two
/// separate requests, and `==` on the peer id would swallow the second one —
/// which is exactly the tap somebody makes after panning away and wanting to
/// come back.
class MapFocusRequest {
  MapFocusRequest(this.peerId);

  final String peerId;
}

final mapFocusRequestProvider = StateProvider<MapFocusRequest?>((ref) => null);
