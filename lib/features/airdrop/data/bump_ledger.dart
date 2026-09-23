import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Who this phone's bump gesture just matched, and when — the receiving
/// side's memory that a person was physically here a moment ago. An offer
/// from that person arriving within [acceptWithin] is the bump itself
/// completing, not a fresh request; see `AirDropController._onOffer`.
class BumpLedger {
  final Map<String, DateTime> _at = {};

  void note(String peerHex, DateTime at) => _at[peerHex] = at;

  bool recent(String peerHex, DateTime now) {
    final at = _at[peerHex];
    return at != null && now.difference(at) <= acceptWithin;
  }

  void clear() => _at.clear();

  static const Duration acceptWithin = Duration(seconds: 10);
}

final bumpLedgerProvider = Provider<BumpLedger>((_) => BumpLedger());
