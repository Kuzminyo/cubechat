import 'package:cubechat/features/airdrop/domain/airdrop_rules.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_spam_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 22, 12);

  SpamRecord declineTimes(SpamRecord start, int n, DateTime at) {
    var r = start;
    for (var i = 0; i < n; i++) {
      r = AirDropSpamGuard.onDecline(AirDropSpamGuard.onRequest(r, at), at);
    }
    return r;
  }

  test('three declines in a row ban for ten minutes', () {
    final first = AirDropSpamGuard.onRequest(null, t0);
    final two = declineTimes(first, 2, t0);
    expect(AirDropSpamGuard.isBanned(two, t0), isFalse);
    final three = declineTimes(first, 3, t0);
    expect(AirDropSpamGuard.isBanned(three, t0), isTrue);
    expect(three.bannedUntil, t0.add(const Duration(minutes: 10)));
    expect(
      AirDropSpamGuard.isBanned(three, t0.add(const Duration(minutes: 10))),
      isFalse,
    );
  });

  test('each ban is twice the last, up to a day', () {
    expect(AirDropSpamGuard.banLength(0), const Duration(minutes: 10));
    expect(AirDropSpamGuard.banLength(1), const Duration(minutes: 20));
    expect(AirDropSpamGuard.banLength(2), const Duration(minutes: 40));
    expect(AirDropSpamGuard.banLength(3), const Duration(minutes: 80));
    expect(AirDropSpamGuard.banLength(8), AirDropRules.maxBan);
    expect(AirDropSpamGuard.banLength(40), AirDropRules.maxBan);
  });

  test('the second round of three bans for twenty minutes', () {
    final firstBan = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final after = firstBan.bannedUntil!;
    final secondBan = declineTimes(firstBan, 3, after);
    expect(secondBan.bannedUntil, after.add(const Duration(minutes: 20)));
  });

  test('an accept starts the count of declines again', () {
    final two = declineTimes(AirDropSpamGuard.onRequest(null, t0), 2, t0);
    final accepted = AirDropSpamGuard.onAccept(two);
    expect(accepted.declines, 0);
    expect(
      AirDropSpamGuard.isBanned(declineTimes(accepted, 2, t0), t0),
      isFalse,
    );
  });

  test('a day without requests forgets everything', () {
    final banned = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final later = t0.add(const Duration(hours: 25));
    final fresh = AirDropSpamGuard.onRequest(banned, later);
    expect(fresh.bans, 0);
    expect(fresh.declines, 0);
    expect(fresh.bannedUntil, isNull);
  });

  test('knocking during a ban keeps the record alive', () {
    final banned = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final during = t0.add(const Duration(minutes: 5));
    final knocked = AirDropSpamGuard.onRequest(banned, during);
    expect(knocked.lastRequestAt, during);
    expect(AirDropSpamGuard.isBanned(knocked, during), isTrue);
  });

  test('a record survives JSON', () {
    final banned = declineTimes(AirDropSpamGuard.onRequest(null, t0), 3, t0);
    final back = SpamRecord.fromJson(banned.toJson())!;
    expect(back.bans, banned.bans);
    expect(back.bannedUntil, banned.bannedUntil);
    expect(back.lastRequestAt, banned.lastRequestAt);
    expect(SpamRecord.fromJson(const {'bans': 'x'}), isNull);
  });
}
