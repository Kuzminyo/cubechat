import 'package:flutter/foundation.dart';

import 'airdrop_rules.dart';

/// What one stranger has done lately. Contacts never get a record.
@immutable
class SpamRecord {
  const SpamRecord({
    required this.lastRequestAt,
    this.declines = 0,
    this.bans = 0,
    this.bannedUntil,
  });

  /// Declines pressed in a row since the last ban or accept.
  final int declines;

  /// Bans served so far — each next one is twice as long.
  final int bans;
  final DateTime? bannedUntil;
  final DateTime lastRequestAt;

  SpamRecord copyWith({
    int? declines,
    int? bans,
    DateTime? bannedUntil,
    DateTime? lastRequestAt,
  }) =>
      SpamRecord(
        declines: declines ?? this.declines,
        bans: bans ?? this.bans,
        bannedUntil: bannedUntil ?? this.bannedUntil,
        lastRequestAt: lastRequestAt ?? this.lastRequestAt,
      );

  Map<String, Object?> toJson() => {
        'declines': declines,
        'bans': bans,
        if (bannedUntil != null) 'until': bannedUntil!.millisecondsSinceEpoch,
        'last': lastRequestAt.millisecondsSinceEpoch,
      };

  static SpamRecord? fromJson(Map<dynamic, dynamic> json) {
    final declines = json['declines'];
    final bans = json['bans'];
    final last = json['last'];
    final until = json['until'];
    if (declines is! int || bans is! int || last is! int) return null;
    if (until != null && until is! int) return null;
    return SpamRecord(
      declines: declines,
      bans: bans,
      bannedUntil:
          until is int ? DateTime.fromMillisecondsSinceEpoch(until) : null,
      lastRequestAt: DateTime.fromMillisecondsSinceEpoch(last),
    );
  }
}

/// The anti-spam rule for strangers, as arithmetic.
///
/// Only a decline the person *pressed* counts: an offer left to expire, or
/// refused because of space or because another one from the same person is
/// already waiting, says nothing about the sender.
abstract final class AirDropSpamGuard {
  static bool isBanned(SpamRecord? r, DateTime now) {
    final until = r?.bannedUntil;
    return until != null && now.isBefore(until);
  }

  /// A request arrived — whether or not it will be shown.
  static SpamRecord onRequest(SpamRecord? r, DateTime now) {
    if (r == null) return SpamRecord(lastRequestAt: now);
    final quiet = now.difference(r.lastRequestAt) >= AirDropRules.forgetAfter;
    if (quiet && !isBanned(r, now)) return SpamRecord(lastRequestAt: now);
    return r.copyWith(lastRequestAt: now);
  }

  static SpamRecord onDecline(SpamRecord r, DateTime now) {
    final declines = r.declines + 1;
    if (declines < AirDropRules.declinesBeforeBan) {
      return r.copyWith(declines: declines);
    }
    return SpamRecord(
      bans: r.bans + 1,
      bannedUntil: now.add(banLength(r.bans)),
      lastRequestAt: r.lastRequestAt,
    );
  }

  static SpamRecord onAccept(SpamRecord r) => r.copyWith(declines: 0);

  static Duration banLength(int bansSoFar) {
    var length = AirDropRules.firstBan;
    for (var i = 0; i < bansSoFar; i++) {
      length *= 2;
      if (length >= AirDropRules.maxBan) return AirDropRules.maxBan;
    }
    return length;
  }
}
