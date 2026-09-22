import 'dart:typed_data';

import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:cubechat/features/airdrop/domain/airdrop_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 9, 22, 12);
final _tid = Uint8List(nearbyIdLen);

AirDropTransfer _transfer({
  AirDropDirection direction = AirDropDirection.outgoing,
  AirDropPhase phase = AirDropPhase.offered,
  int files = 2,
  DateTime? acceptedAt,
}) =>
    AirDropTransfer(
      id: nearbyHex(_tid),
      peerHex: 'bb' * 32,
      peerName: 'Жека',
      direction: direction,
      files: [
        for (var i = 0; i < files; i++)
          AirDropFile(
            mediaIdHex: 'f$i',
            name: 'p$i.jpg',
            size: 100,
            mime: 'image/jpeg',
          ),
      ],
      phase: phase,
      createdAt: _t0,
      acceptedAt: acceptedAt,
      lastProgressAt: acceptedAt,
    );

NearbyAnswer _answer(
  NearbyAnswerKind kind, [
  NearbyDeclineReason reason = NearbyDeclineReason.user,
]) =>
    NearbyAnswer(transferId: _tid, kind: kind, reason: reason);

void main() {
  group('outgoing', () {
    test('seen, then accepted', () {
      final seen = AirDropTransitions.onAnswer(
        _transfer(),
        _answer(NearbyAnswerKind.seen),
        _t0,
      );
      expect(seen.phase, AirDropPhase.waiting);
      final accepted = AirDropTransitions.onAnswer(
        seen,
        _answer(NearbyAnswerKind.accepted),
        _t0,
      );
      expect(accepted.phase, AirDropPhase.transferring);
      expect(accepted.acceptedAt, _t0);
    });

    test('no seen in time says unheard, and a late seen still counts', () {
      final unheard = AirDropTransitions.onSeenTimeout(_transfer());
      expect(unheard.phase, AirDropPhase.unheard);
      expect(
        AirDropTransitions.onSeenTimeout(
          _transfer(phase: AirDropPhase.waiting),
        ).phase,
        AirDropPhase.waiting,
      );
      expect(
        AirDropTransitions.onAnswer(
          unheard,
          _answer(NearbyAnswerKind.seen),
          _t0,
        ).phase,
        AirDropPhase.waiting,
      );
    });

    test('a decline carries its reason', () {
      final declined = AirDropTransitions.onAnswer(
        _transfer(phase: AirDropPhase.waiting),
        _answer(NearbyAnswerKind.declined, NearbyDeclineReason.noSpace),
        _t0,
      );
      expect(declined.phase, AirDropPhase.declined);
      expect(declined.reason, NearbyDeclineReason.noSpace);
    });

    test('nothing moves a finished transfer', () {
      final done = _transfer(phase: AirDropPhase.done);
      for (final kind in NearbyAnswerKind.values) {
        expect(
          AirDropTransitions.onAnswer(done, _answer(kind), _t0).phase,
          AirDropPhase.done,
        );
      }
    });

    test('an offer nobody answers fails', () {
      for (final phase in [
        AirDropPhase.offered,
        AirDropPhase.unheard,
        AirDropPhase.waiting,
      ]) {
        expect(
          AirDropTransitions.onOfferExpired(_transfer(phase: phase)).phase,
          AirDropPhase.failed,
        );
      }
      expect(
        AirDropTransitions.onOfferExpired(
          _transfer(phase: AirDropPhase.transferring, acceptedAt: _t0),
        ).phase,
        AirDropPhase.transferring,
      );
    });

    test('a retry inside ten minutes resumes; after, it does not', () {
      final broken = AirDropTransitions.interrupt(
        _transfer(phase: AirDropPhase.transferring, acceptedAt: _t0),
      );
      expect(broken.phase, AirDropPhase.interrupted);
      expect(
        AirDropTransitions.retry(broken, _t0.add(const Duration(minutes: 9)))
            .phase,
        AirDropPhase.transferring,
      );
      expect(
        AirDropTransitions.retry(broken, _t0.add(const Duration(minutes: 10)))
            .phase,
        AirDropPhase.interrupted,
      );
    });
  });

  group('incoming', () {
    AirDropTransfer request() => _transfer(
          direction: AirDropDirection.incoming,
          phase: AirDropPhase.waiting,
        );

    test('accept, decline and the sixty-second timeout act on a request only',
        () {
      expect(request().isIncomingRequest, isTrue);
      expect(
        AirDropTransitions.accept(request(), _t0).phase,
        AirDropPhase.transferring,
      );
      final declined =
          AirDropTransitions.decline(request(), NearbyDeclineReason.user);
      expect(declined.phase, AirDropPhase.declined);
      final expired = AirDropTransitions.onAnswerTimeout(request());
      expect(expired.phase, AirDropPhase.declined);
      expect(expired.reason, NearbyDeclineReason.timeout);
      final moving = AirDropTransitions.accept(request(), _t0);
      expect(AirDropTransitions.onAnswerTimeout(moving), same(moving));
    });

    test('files arrive one by one and the last one finishes it', () {
      var t = AirDropTransitions.accept(request(), _t0);
      t = AirDropTransitions.onFileDone(t, 'f0', '/a/p0.jpg', _t0);
      expect(t.doneCount, 1);
      expect(t.files.first.path, '/a/p0.jpg');
      expect(t.phase, AirDropPhase.transferring);
      t = AirDropTransitions.onFileDone(t, 'f1', '/a/p1.jpg', _t0);
      expect(t.phase, AirDropPhase.done);
    });

    test('a file for a request not yet accepted changes nothing', () {
      expect(
        AirDropTransitions.onFileDone(request(), 'f0', '/a', _t0).doneCount,
        0,
      );
    });

    test('sixty seconds without a piece interrupts, a file resumes it', () {
      final moving = AirDropTransitions.accept(request(), _t0);
      expect(
        AirDropTransitions.onStall(
          moving,
          _t0.add(const Duration(seconds: 59)),
        ).phase,
        AirDropPhase.transferring,
      );
      final stalled = AirDropTransitions.onStall(
        moving,
        _t0.add(const Duration(seconds: 60)),
      );
      expect(stalled.phase, AirDropPhase.interrupted);
      final resumed = AirDropTransitions.onFileDone(
        stalled,
        'f0',
        '/a/p0.jpg',
        _t0.add(const Duration(minutes: 2)),
      );
      expect(resumed.phase, AirDropPhase.transferring);
    });

    test('an interrupted transfer ends when its acceptance runs out', () {
      final stalled = AirDropTransitions.interrupt(
        AirDropTransitions.accept(request(), _t0),
      );
      final later = _t0.add(const Duration(minutes: 10));
      expect(
        AirDropTransitions.expire(stalled, later).phase,
        AirDropPhase.failed,
      );
      final one = AirDropTransitions.onFileDone(stalled, 'f0', '/a', _t0);
      expect(
        AirDropTransitions.expire(AirDropTransitions.interrupt(one), later)
            .phase,
        AirDropPhase.partial,
      );
    });
  });

  test('stopping keeps what already arrived', () {
    final moving = AirDropTransitions.accept(
      _transfer(
        direction: AirDropDirection.incoming,
        phase: AirDropPhase.waiting,
      ),
      _t0,
    );
    expect(AirDropTransitions.stop(moving).phase, AirDropPhase.cancelled);
    final one = AirDropTransitions.onFileDone(moving, 'f0', '/a', _t0);
    expect(AirDropTransitions.stop(one).phase, AirDropPhase.partial);
    expect(
      AirDropTransitions.stop(_transfer(phase: AirDropPhase.done)).phase,
      AirDropPhase.done,
    );
  });
}
