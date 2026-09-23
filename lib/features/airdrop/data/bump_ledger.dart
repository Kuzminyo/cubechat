import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Who this phone's bump gesture just matched, and when — the receiving
/// side's memory that a person was physically here a moment ago. An offer
/// from that person arriving within [acceptWithin] is the bump itself
/// completing, not a fresh request; see `AirDropController._onOffer`.
class BumpLedger {
  final Map<String, DateTime> _at = {};

  void note(String peerHex, DateTime at) => _at[peerHex] = at;

  /// One bump buys exactly one auto-accepted offer: the spec ties the
  /// auto-accept to *the* offer that follows the gesture, not to every offer
  /// that happens to arrive in the next ten seconds. So this both answers
  /// "was the bump recent enough" and spends the note — found or not, it is
  /// gone after this call, and a second offer from the same person goes
  /// through the ordinary rules.
  bool take(String peerHex, DateTime now) {
    final at = _at.remove(peerHex);
    return at != null && now.difference(at) <= acceptWithin;
  }

  void clear() => _at.clear();

  static const Duration acceptWithin = Duration(seconds: 10);
}

final bumpLedgerProvider = Provider<BumpLedger>((_) => BumpLedger());
